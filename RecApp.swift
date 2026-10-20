import AVFoundation
import AppKit
import ScreenCaptureKit
import SwiftUI

// Writes one audio source to its own m4a. The encoder is created from the first buffer's format
// because the mic (e.g. AirPods at 16/24kHz mono) and system audio (48kHz stereo) differ.
final class TrackWriter {
  let url: URL
  private let start: CMTime
  private var writer: AVAssetWriter?
  private var input: AVAssetWriterInput?
  private(set) var failure: Error?
  // Seconds between the shared start time and this source's first buffer, used to align the mix
  private(set) var offset: Double = 0

  init(url: URL, start: CMTime) {
    self.url = url
    self.start = start
  }

  func append(_ sb: CMSampleBuffer) {
    guard failure == nil, sb.isValid, sb.presentationTimeStamp >= start else { return }
    if writer == nil {
      guard let asbd = sb.formatDescription?.audioStreamBasicDescription else { return }
      do {
        let w = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [
          AVFormatIDKey: kAudioFormatMPEG4AAC,
          AVSampleRateKey: asbd.mSampleRate,
          AVNumberOfChannelsKey: min(asbd.mChannelsPerFrame, 2),
        ])
        i.expectsMediaDataInRealTime = true
        w.add(i)
        guard w.startWriting() else { throw w.error ?? NSError(domain: "Rec", code: 3) }
        w.startSession(atSourceTime: sb.presentationTimeStamp)
        offset = (sb.presentationTimeStamp - start).seconds
        writer = w
        input = i
      } catch {
        failure = error
        return
      }
    }
    if let i = input, i.isReadyForMoreMediaData { i.append(sb) }
  }

  func finish() async {
    guard let w = writer else { return }
    input?.markAsFinished()
    await w.finishWriting()
    if w.status == .failed { failure = w.error }
  }
}

@MainActor
final class Recorder: NSObject, ObservableObject, SCStreamDelegate, SCStreamOutput {
  @Published var startedAt: Date?
  @Published var saving = false
  @Published var lastFile: URL?
  @Published var error: String?

  private var stream: SCStream?
  private var base: URL?
  // Touched only on `queue`
  nonisolated(unsafe) private var system: TrackWriter?
  nonisolated(unsafe) private var mic: TrackWriter?
  private let queue = DispatchQueue(label: "rec.audio")

  var micName: String { AVCaptureDevice.default(for: .audio)?.localizedName ?? "없음" }

  func start() async {
    error = nil
    guard await AVCaptureDevice.requestAccess(for: .audio) else {
      error = "마이크 권한이 없어요. 시스템 설정에서 허용해 주세요."
      return
    }
    do {
      let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
      guard let display = content.displays.first else { throw NSError(domain: "Rec", code: 1, userInfo: [NSLocalizedDescriptionKey: "디스플레이 없음"]) }

      let config = SCStreamConfiguration()
      config.capturesAudio = true
      config.captureMicrophone = true  // system default input
      // SCStream always captures video; keep it tiny since no screen output consumes it
      config.width = 2
      config.height = 2
      config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

      // ~/Movies isn't TCC-protected, unlike ~/Desktop
      let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Movies/Rec")
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "")
      let base = dir.appending(path: "rec-\(stamp)")

      let t0 = CMClockGetTime(CMClockGetHostTimeClock())
      let system = TrackWriter(url: URL(fileURLWithPath: base.path + "-system.m4a"), start: t0)
      let mic = TrackWriter(url: URL(fileURLWithPath: base.path + "-mic.m4a"), start: t0)
      queue.sync {
        self.system = system
        self.mic = mic
      }

      let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: self)
      try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
      try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
      try await s.startCapture()
      stream = s
      self.base = base
      lastFile = nil
      startedAt = Date()
    } catch {
      self.error = "\(error.localizedDescription)\n화면 및 시스템 오디오 녹음 권한을 허용했다면 앱을 다시 켜 주세요."
    }
  }

  func stop() async {
    guard let s = stream, let base else { return }
    saving = true
    try? await s.stopCapture()
    stream = nil
    startedAt = nil
    let (system, mic) = queue.sync { (self.system, self.mic) }
    await system?.finish()
    await mic?.finish()
    queue.sync {
      self.system = nil
      self.mic = nil
    }

    let parts = [system, mic].compactMap { $0 }.filter { FileManager.default.fileExists(atPath: $0.url.path) }.map { (url: $0.url, offset: $0.offset) }
    if let e = [system, mic].compactMap({ $0?.failure }).first {
      error = "트랙 저장 실패: \(e.localizedDescription)"
    }
    let mixed = base.appendingPathExtension("m4a")
    do {
      try await Task.detached { try Self.mix(parts, to: mixed) }.value
      lastFile = mixed
    } catch {
      self.error = "합친 파일 저장 실패, 트랙별 파일은 남아 있어요: \(error.localizedDescription)"
      lastFile = parts.first?.url
    }
    saving = false
  }

  // AVMutableComposition export fails (-12780) on these files, so render the mix offline instead
  nonisolated private static func mix(_ parts: [(url: URL, offset: Double)], to url: URL) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    let engine = AVAudioEngine()
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
    var length: AVAudioFramePosition = 0
    var players: [AVAudioPlayerNode] = []
    for part in parts {
      let file = try AVAudioFile(forReading: part.url)
      let player = AVAudioPlayerNode()
      engine.attach(player)
      engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
      let start = AVAudioFramePosition(part.offset * format.sampleRate)
      player.scheduleFile(file, at: AVAudioTime(sampleTime: start, atRate: format.sampleRate))
      length = max(length, start + AVAudioFramePosition(Double(file.length) * format.sampleRate / file.processingFormat.sampleRate))
      players.append(player)
    }
    try engine.start()
    players.forEach { $0.play() }

    let out = try AVAudioFile(forWriting: url, settings: [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: format.sampleRate,
      AVNumberOfChannelsKey: format.channelCount,
    ])
    let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount)!
    while engine.manualRenderingSampleTime < length {
      let frames = min(AVAudioFrameCount(length - engine.manualRenderingSampleTime), buffer.frameCapacity)
      guard try engine.renderOffline(frames, to: buffer) == .success else {
        throw NSError(domain: "Rec", code: 4, userInfo: [NSLocalizedDescriptionKey: "믹스 렌더링 실패"])
      }
      try out.write(from: buffer)
    }
    engine.stop()
    out.close()
  }

  nonisolated func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
    switch type {
    case .audio: system?.append(sb)
    case .microphone: mic?.append(sb)
    default: break
    }
  }

  nonisolated func stream(_ s: SCStream, didStopWithError e: Error) {
    Task { @MainActor in
      error = "캡처 중단: \(e.localizedDescription)"
      await stop()
    }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  var recorder: Recorder!
  func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
  // Quitting mid-recording would leave a broken .mov, so finalize first
  func applicationShouldTerminate(_ app: NSApplication) -> NSApplication.TerminateReply {
    guard recorder.startedAt != nil else { return .terminateNow }
    Task { @MainActor in
      await recorder.stop()
      app.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}

struct ContentView: View {
  @ObservedObject var recorder: Recorder

  var body: some View {
    VStack(spacing: 14) {
      if let start = recorder.startedAt {
        TimelineView(.periodic(from: start, by: 1)) { ctx in
          let t = Int(ctx.date.timeIntervalSince(start))
          Text(String(format: "● %d:%02d:%02d", t / 3600, t / 60 % 60, t % 60))
            .font(.system(size: 28, weight: .semibold, design: .monospaced))
            .foregroundStyle(.red)
        }
      } else {
        Text(recorder.saving ? "저장 중…" : "대기 중").font(.system(size: 28, weight: .semibold))
      }

      Button(recorder.startedAt == nil ? "녹음 시작" : "녹음 종료") {
        Task { recorder.startedAt == nil ? await recorder.start() : await recorder.stop() }
      }
      .controlSize(.large)
      .keyboardShortcut(.defaultAction)
      .disabled(recorder.saving)

      Text("마이크: \(recorder.micName)").font(.caption).foregroundStyle(.secondary)

      if let e = recorder.error {
        Text(e).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
      }
      if let f = recorder.lastFile, recorder.startedAt == nil, !recorder.saving {
        Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([f]) }
          .buttonStyle(.link)
      }
    }
    .padding(24)
    .frame(width: 300)
  }
}

@main
struct RecApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
  @StateObject var recorder = Recorder()

  var body: some Scene {
    Window("Rec", id: "main") {
      ContentView(recorder: recorder).onAppear { delegate.recorder = recorder }
    }
    .windowResizability(.contentSize)
  }
}
