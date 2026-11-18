import Synchronization

@available(iOS 18, macOS 15, *)
enum ParallelWork {
	private struct State<Input: Sendable, Output: Sendable>: Sendable {
		var inputs: [Input]
		var outputs: [Output]
	}

	private static func work<Input: Sendable, Output: Sendable>(
		state: borrowing Mutex<State<Input, Output>>,
		operation: @Sendable (Input) -> Output
	) {
		var input: Input?
		while true {
			input = state.withLock { $0.inputs.popLast() }
			guard input != nil else { return }
			let output = operation(input!)
			input = nil
			state.withLock { $0.outputs.append(output) }
		}
	}

	static func drain<Input: Sendable, Output: Sendable>(
		_ inputs: consuming [Input], maximumWorkers: Int,
		runner: any ParallelRunner,
		operation: @Sendable (Input) -> Output
	) -> [Output] {
		precondition(maximumWorkers > 0)
		let inputCount = inputs.count
		let state = Mutex<State<Input, Output>>(
			State<Input, Output>(inputs: consume inputs, outputs: [Output]()))
		runner.run(iterations: min(maximumWorkers, inputCount)) { _ in
			work(state: state, operation: operation)
		}
		return state.withLock { $0.outputs }
	}
}
