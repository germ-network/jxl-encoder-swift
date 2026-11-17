//
//  EncoderError.swift
//  JXLEncoder
//

public enum EncoderError: Error, Equatable, Sendable {
	case emptyImage
	case imageTooLarge(width: Int, height: Int)
	/// libjxl-tiny's VarDCT path has no lossless mode; distance 0 is rejected
	/// rather than silently encoded at the minimum distance.
	case losslessNotSupported
	case invalidDistance(Float)
	/// The requested number of parallel workers must be positive.
	case invalidWorkerCount(Int)
	/// DC preparation cannot represent a sample or residual safely.
	case unsupportedDCRange
	case pixelCountMismatch(expected: Int, actual: Int)
	/// Only 3 (RGB) and 4 (RGBA stride, alpha ignored) are meaningful; anything
	/// else would misalign every pixel read.
	case unsupportedChannelCount(Int)
}
