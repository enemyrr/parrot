import AppKit
import ArgumentParser
import Foundation

/// `parrot squawk "answer this, ten o'clock works"` — the whole squawk path
/// with the microphone taken out of it.
///
/// Types the answer for real unless `--dry-run` says otherwise, so it can be
/// used as a keyboard-only squawk. Mostly it exists so the prompt, the context
/// and the model can be checked one at a time: when an answer comes out wrong,
/// this says whether the model was given the wrong material or made the wrong
/// thing out of it.
struct SquawkCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "squawk",
        abstract: "Run a squawk from the command line, without talking."
    )

    @Argument(help: "What you would have said.")
    var instruction: String

    @Option(name: .long, help: "Read this app instead of whatever is in front.")
    var app: String?

    @Option(name: .long, help: "Override the provider: apple, anthropic or openai.")
    var provider: String?

    @Option(name: .long, help: "Override the model id.")
    var model: String?

    @Flag(name: .long, help: "Print the answer instead of typing it.")
    var dryRun: Bool = false

    @Flag(name: .long, help: "Print the exact prompt that gets sent, and stop.")
    var showPrompt: Bool = false

    @Option(name: .long, help: "Seconds to wait before reading the screen.")
    var delay: Double = 0

    func run() throws {
        var settings = SettingsStore.current().squawk
        if let provider {
            guard let parsed = LLMProvider(rawValue: provider) else {
                throw ValidationError("Unknown provider '\(provider)'. Use apple, anthropic or openai.")
            }
            settings.provider = parsed
        }
        if let model { settings.model = model }

        if delay > 0 {
            print("Reading the screen in \(Int(delay))s…")
            Thread.sleep(forTimeInterval: delay)
        }

        let target = MainActor.assumeIsolated {
            app.flatMap(AppTarget.named) ?? AppTarget.frontmost()
        }
        let context = target.map { target -> ScreenContext in
            settings.isExcluded(bundleID: target.bundleID)
                ? .skipped(.excludedApp, app: target.name, bundleID: target.bundleID)
                : ScreenReader.capture(target, limits: settings.context.limits)
        }

        let profile = settings.profile(for: context?.bundleID)
        let system = SquawkPrompt.system(
            settings: settings,
            profile: profile,
            languages: LanguageSelection.displayNames(SettingsStore.current().languages)
        )
        let user = SquawkPrompt.user(instruction: instruction, context: context)

        if showPrompt {
            print("──────── system ────────")
            print(system)
            print("\n──────── user ────────")
            print(user)
            return
        }

        let client: LLMClient
        switch makeLLMClient(
            provider: settings.provider,
            model: settings.model,
            reasoningEffort: settings.reasoningEffort.rawValue
        ) {
        case .success(let made): client = made
        case .failure(let error):
            print("Can't run: \(error)")
            throw ExitCode(1)
        }

        let fallback: SquawkResponse.Action =
            (context?.selection?.isEmpty == false) ? .replace : .insert

        print("app      \(context?.app ?? "—")\(profile.map { "  ·  profile: \($0.name)" } ?? "")")
        print("context  \(context?.characterCount ?? 0) chars")
        print("model    \(client.name)")
        print("")

        // ArgumentParser's `run` is synchronous, so the async call is bridged
        // through a semaphore rather than restructuring the whole CLI around
        // an async entry point for one subcommand. The request is built out
        // here: capturing the mutable `settings` into the closure is an error
        // under Swift 6 concurrency checking.
        let request = LLMRequest(
            system: system,
            user: user,
            maxOutputTokens: max(512, settings.maxCharacters / 2),
            reasoningEffort: settings.reasoningEffort.rawValue,
            schema: SquawkPrompt.schema
        )
        let timeout = settings.timeoutS
        let result = runBlocking { () -> Result<String, Error> in
            do {
                return .success(try await withDeadline(timeout) {
                    try await client.complete(request)
                })
            } catch {
                return .failure(error)
            }
        }

        let raw: String
        switch result {
        case .success(let value): raw = value
        case .failure(let error):
            print("Failed: \((error as? LLMError)?.description ?? "\(error)")")
            throw ExitCode(1)
        }

        guard let parsed = SquawkResponse.parse(raw, fallback: fallback) else {
            print("Nothing usable came back:\n\(raw)")
            throw ExitCode(1)
        }
        let text = SquawkGuard.unwrap(parsed.text)
        guard SquawkGuard.accept(text, maxCharacters: settings.maxCharacters) else {
            print("Rejected by the guard (refusal or too long):\n\(text)")
            throw ExitCode(1)
        }

        print("──────── \(parsed.action.rawValue) ────────")
        print(text)

        if !dryRun {
            print("\nTyping it in 3s — click where you want it.")
            Thread.sleep(forTimeInterval: 3)
            TextInjector.put(text)
            // The paste path restores the clipboard on a delay, so the process
            // has to outlive it.
            RunLoop.main.run(until: Date().addingTimeInterval(1))
        }
    }
}

/// Bridges one async call into a synchronous `ParsableCommand.run`.
func runBlocking<T: Sendable>(_ operation: @escaping @Sendable () async -> T) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    // `nonisolated(unsafe)` rather than a lock: exactly one write happens
    // before the semaphore is signalled, and exactly one read after.
    nonisolated(unsafe) var result: T?
    Task {
        result = await operation()
        semaphore.signal()
    }
    semaphore.wait()
    return result!
}
