import AVFoundation
import AppKit
import ScreenCaptureKit
import SwiftUI

@MainActor
final class Recorder: NSObject, ObservableObject, SCStreamDelegate, SCRecordingOutputDelegate {
  @Published var startedAt: Date?
  @Published var saving = false
  @Published var lastFile: URL?
  @Published var error: String?

  private var stream: SCStream?
  private var finished: CheckedContinuation<Void, Never>?

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
      config.width = 320
      config.height = 180
      config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

      // ~/Movies isn't TCC-protected, unlike ~/Desktop
      let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Movies/Rec")
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "")
      let url = dir.appending(path: "rec-\(stamp).mov")

      let rc = SCRecordingOutputConfiguration()
      rc.outputURL = url
      rc.outputFileType = .mov
      let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: self)
      try s.addRecordingOutput(SCRecordingOutput(configuration: rc, delegate: self))
      try await s.startCapture()
      stream = s
      lastFile = url
      startedAt = Date()
    } catch {
      self.error = "\(error.localizedDescription)\n화면 및 시스템 오디오 녹음 권한을 허용했다면 앱을 다시 켜 주세요."
    }
  }

  func stop() async {
    guard let s = stream else { return }
    saving = true
    await withCheckedContinuation { c in
      finished = c
      Task { try? await s.stopCapture() }
    }
    stream = nil
    startedAt = nil
    saving = false
  }

  nonisolated func recordingOutputDidFinishRecording(_ r: SCRecordingOutput) {
    Task { @MainActor in finished?.resume(); finished = nil }
  }
  nonisolated func recordingOutput(_ r: SCRecordingOutput, didFailWithError e: Error) {
    Task { @MainActor in error = "녹음 실패: \(e.localizedDescription)"; finished?.resume(); finished = nil; stream = nil; startedAt = nil }
  }
  nonisolated func stream(_ s: SCStream, didStopWithError e: Error) {
    Task { @MainActor in error = "캡처 중단: \(e.localizedDescription)"; finished?.resume(); finished = nil; stream = nil; startedAt = nil }
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
