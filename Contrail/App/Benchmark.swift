import AppKit
import ContrailCore

/// Measures what Contrail costs, with a scripted cursor instead of the real
/// one (the real mouse is never moved):
///
///     Contrail.app/Contents/MacOS/Contrail --benchmark [--style sparks]
///
/// Draws a fast trail on the main screen for 4 s, then stops and waits for
/// the app to go idle. Prints CPU use and memory for both phases, then quits.
/// Uses default settings in a throwaway defaults domain, so your own
/// settings are neither used nor changed.
@MainActor
enum Benchmark {
    private static var activity: NSObjectProtocol?
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard args.contains("--benchmark") else { return }
        // Keep App Nap from delaying the benchmark's own timers.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical], reason: "Contrail benchmark")
        let suite = "io.github.kiril-p.contrail.benchmark"
        UserDefaults().removePersistentDomain(forName: suite)
        let store = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        if let i = args.firstIndex(of: "--style"), i + 1 < args.count, let style = TrailStyle(rawValue: args[i + 1]) {
            store.settings.style = style
        }
        let activation = ActivationController(store: store)
        let controller = TrailController(store: store, activation: activation)
        let screen = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let start = CACurrentMediaTime()
        var moving = true
        var still = CGPoint(x: screen.midX, y: screen.midY)
        controller.cursorSource = {
            guard moving else { return still }
            // A fast figure-eight across most of the screen (~1500 pt/s).
            let t = CACurrentMediaTime() - start
            still = CGPoint(x: screen.midX + screen.width * 0.35 * sin(t * 2.2),
                            y: screen.midY + screen.height * 0.3 * sin(t * 4.4))
            return still
        }
        controller.listensToMouse = false
        controller.start()
        controller.wakeForBenchmark()

        // A moving cursor keeps the trail from emptying, so the display
        // links keep running without mouse events.

        let launch = footprintMB()
        after(1) {   // warm up
            let cpu0 = cpuSeconds(), frames0 = controller.frameCount, t0 = CACurrentMediaTime()
            let model0 = controller.modelSeconds, draw0 = controller.drawSeconds
            after(4) {
                let wall = CACurrentMediaTime() - t0
                let cpu = cpuSeconds() - cpu0
                let frames = controller.frameCount - frames0
                let model = (controller.modelSeconds - model0) / Double(max(frames, 1)) * 1000
                let draw = (controller.drawSeconds - draw0) / Double(max(frames, 1)) * 1000
                let active = footprintMB()
                moving = false
                after(8) {   // drain, sleep, release
                    let idle = footprintMB()
                    let cpu1 = cpuSeconds(), t1 = CACurrentMediaTime(), frames1 = controller.frameCount
                    after(5) {
                        let idleCPU = (cpuSeconds() - cpu1) / (CACurrentMediaTime() - t1) * 100
                        let idleFrames = controller.frameCount - frames1
                        // Wake again after the buffers were given back.
                        moving = true
                        controller.wakeForBenchmark()
                        let frames2 = controller.frameCount, t2 = CACurrentMediaTime()
                        after(1) {
                        UserDefaults().removePersistentDomain(forName: suite)
                        moving = false
                        print(String(format: """
                        style            %@
                        launch footprint %.1f MB
                        active CPU       %.1f%% of one core (%.0f fps, %.2f ms CPU per frame)
                        per frame        model %.3f ms, draw %.3f ms (main thread)
                        active footprint %.1f MB
                        idle footprint   %.1f MB
                        idle CPU         %.2f%%, %d frames
                        woken again      %.0f fps, footprint %.1f MB
                        """, store.settings.style.rawValue, launch, cpu / wall * 100, Double(frames) / wall,
                              cpu / Double(max(frames, 1)) * 1000, model, draw, active, idle, idleCPU,
                              idleFrames, Double(controller.frameCount - frames2) / (CACurrentMediaTime() - t2),
                              footprintMB()))
                        exit(0)
                        }
                    }
                }
            }
        }
    }

    private static func after(_ seconds: Double, _ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated(body) }
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}
