import Foundation
import Testing

@testable import JXLEncoder

@Suite("JPEG chroma from luma production consumers")
struct JPEGCfLIntegrationTests {
	@Test(
		"Serialized RGB frames signal RGB and recover source quantizers and coefficients",
		.enabled(
			if: ProcessInfo.processInfo.environment["JXL_RGB_EXPORT_DIR"] != nil
				|| ProcessInfo.processInfo.environment["JXL_RGB_CHECK_DIR"] != nil)
	)
	func actualRGBJPEGSerializationCrossCheck() throws {
		let exportPath = ProcessInfo.processInfo.environment["JXL_RGB_EXPORT_DIR"]
		let checkPath = ProcessInfo.processInfo.environment["JXL_RGB_CHECK_DIR"]
		#expect((exportPath == nil) != (checkPath == nil))
		let names = ["rgb_color", "rgb_coded_dc"]
		if let exportPath {
			let directory = URL(fileURLWithPath: exportPath, isDirectory: true)
			try FileManager.default.createDirectory(
				at: directory, withIntermediateDirectories: true)
			for name in names {
				let jpeg = try JPEGParserTests.fixture(name)
				let stream = try #require(Encoder.recompressJPEG(jpeg))
				#expect(JXLSignature.matches(stream))
				try Data(stream).write(
					to: directory.appendingPathComponent(
						"\(name)-optimized.jxl"))
			}
			return
		}
		let directory = URL(fileURLWithPath: try #require(checkPath), isDirectory: true)
		for name in names {
			for suffix in ["optimized"] {
				let actual = try SemanticDump(
					parsing: String(
						contentsOf: directory.appendingPathComponent(
							"\(name)-\(suffix).rgb.sem"),
						encoding: .utf8))
				for field in [
					"jpeg_rgb.source_is_rgb", "jpeg_rgb.no_color_transform",
					"jpeg_rgb.srgb_metadata", "jpeg_rgb.sampling_444",
					"jpeg_rgb.skip_smoothing", "jpeg_rgb.coefficients_exact",
					"jpeg_rgb.quantizers_exact",
				] {
					#expect(
						actual.fields[field] == .integers([1]),
						"\(name) \(suffix): \(field)")
				}
				let cfl = try #require(actual.fields["jpeg_cfl.ytox_map"])
				if case .integers(let values) = cfl {
					if name == "rgb_coded_dc" {
						#expect(values.contains(where: { $0 != 0 }))
					}
				} else {
					Issue.record("RGB CfL map was not integral")
				}
			}
		}
		let optimized = try SemanticDump(
			parsing: String(
				contentsOf: directory.appendingPathComponent(
					"rgb_coded_dc-optimized.rgb.sem"),
				encoding: .utf8))
		#expect(optimized.fields["jpeg_rgb.green_thresholds"] == .integers([203]))
		#expect(optimized.fields["jpeg_rgb.ac_bucket_context_changes"] == .integers([1]))
	}

	@Test("Ordering and tokenization consume the same mapped residuals")
	func jpegCfLOrderingAndTokenizationUseResiduals() throws {
		let dcGroupBlocks = Geometry.dcGroupDim / Geometry.blockDim
		let blockCount = dcGroupBlocks * 2
		var luma = [Int32](repeating: 0, count: blockCount * 64)
		var cb = [Int32](repeating: 0, count: blockCount * 64)
		var cr = [Int32](repeating: 0, count: blockCount * 64)
		luma[dcGroupBlocks * 64] = 23
		luma[dcGroupBlocks * 64 + 1] = 84
		luma[dcGroupBlocks * 64 + 2] = 84
		cb[dcGroupBlocks * 64] = 17
		cb[dcGroupBlocks * 64 + 1] = 10
		cb[dcGroupBlocks * 64 + 2] = 10
		cr[dcGroupBlocks * 64] = -19
		cr[dcGroupBlocks * 64 + 1] = -10
		cr[dcGroupBlocks * 64 + 2] = -10
		let transcode = try JPEGCfLTests.transcode(
			luma: luma, cb: cb, cr: cr, blocksPerLine: blockCount)
		#expect(transcode.block(channel: 1, x: dcGroupBlocks, y: 0)[8] == 84)
		#expect(transcode.block(channel: 0, x: dcGroupBlocks, y: 0)[8] == 10)
		var data = DCGroupData(widthInBlocks: dcGroupBlocks, heightInBlocks: 1)
		transcode.populateColorCorrelation(
			data: &data, blockX0: dcGroupBlocks, blockY0: 0)
		#expect(data.ytoxMap[0] == 10)
		#expect(data.ytobMap[0] == -10)
		let ordered = try ACGroupEncoder.jpegCoefficientsForOrdering(
			transcode: transcode, colorCorrelation: data,
			colorCorrelationBlockX0: dcGroupBlocks, colorCorrelationBlockY0: 0,
			blockX0: dcGroupBlocks, blockY0: 0,
			widthInBlocks: 1, heightInBlocks: 1)
		#expect(ordered[0][0] == 17)
		#expect(ordered[1][0] == 23)
		#expect(ordered[2][0] == -19)
		#expect(ordered[0][8] == 0)
		#expect(ordered[0][16] == 0)
		#expect(ordered[1][8] == 84)
		#expect(ordered[1][16] == 84)
		#expect(ordered[2][8] == 0)
		#expect(ordered[2][16] == 0)
		var rawDC = [[Int32]](repeating: [0], count: 3)
		var rawWriter = SectionWriter(mode: .direct(.staticAC))
		ACGroupEncoder.encodeJPEG(
			transcode: transcode, blockX0: dcGroupBlocks, blockY0: 0,
			widthInBlocks: 1, heightInBlocks: 1, quantDC: &rawDC,
			blockContextMap: nil, order: CoeffOrder.Result.identity.orders,
			writer: &rawWriter)
		var mappedDC = [[Int32]](repeating: [0], count: 3)
		var mappedWriter = SectionWriter(mode: .direct(.staticAC))
		try ACGroupEncoder.encodeJPEG(
			transcode: transcode, colorCorrelation: data,
			colorCorrelationBlockX0: dcGroupBlocks, colorCorrelationBlockY0: 0,
			blockX0: dcGroupBlocks, blockY0: 0,
			widthInBlocks: 1, heightInBlocks: 1,
			quantDC: &mappedDC, blockContextMap: nil,
			order: CoeffOrder.Result.identity.orders, writer: &mappedWriter)
		#expect(rawDC == [[17], [23], [-19]])
		#expect(mappedDC == rawDC)
		#expect(rawWriter.bitsWritten != mappedWriter.bitsWritten)
	}

	@Test(
		"Actual Swift streams recover source coefficients",
		.enabled(
			if: ProcessInfo.processInfo.environment["JXL_CFL_EXPORT_DIR"] != nil
				|| ProcessInfo.processInfo.environment["JXL_CFL_CHECK_DIR"] != nil)
	)
	func actualJPEGCfLSerializationCrossCheck() throws {
		let exportPath = ProcessInfo.processInfo.environment["JXL_CFL_EXPORT_DIR"]
		let checkPath = ProcessInfo.processInfo.environment["JXL_CFL_CHECK_DIR"]
		#expect((exportPath == nil) != (checkPath == nil))
		if let exportPath {
			let directory = URL(fileURLWithPath: exportPath, isDirectory: true)
			try FileManager.default.createDirectory(
				at: directory, withIntermediateDirectories: true)
			for name in [
				"small_444", "cfl_endpoint_444", "cfl_tile_65x8", "small_422",
				"hopper_gray_odd",
			] {
				let transcode = try JPEGTranscode(
					JPEGParser.parse(JPEGSemanticCorpusEntry.jpegBytes(name)))
				let alignment = (
					x: 1 << transcode.subsampling.maxHorizontalShift,
					y: 1 << transcode.subsampling.maxVerticalShift
				)
				let dim = ImageDim(
					width: transcode.width, height: transcode.height,
					blockAlignment: alignment)
				var data = DCGroupData(
					widthInBlocks: dim.widthInBlocks,
					heightInBlocks: dim.heightInBlocks,
					subsampling: transcode.subsampling)
				transcode.populateColorCorrelation(
					data: &data, blockX0: 0, blockY0: 0)
				let expected = """
					jxl-semantic-dump 1
					jpeg_cfl.map_size i 2 \(data.cmapWidth) \(data.cmapHeight)
					jpeg_cfl.ytox_map i \(data.ytoxMap.count) \(data.ytoxMap.map(String.init).joined(separator: " "))
					jpeg_cfl.ytob_map i \(data.ytobMap.count) \(data.ytobMap.map(String.init).joined(separator: " "))
					"""
					.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
				try expected.write(
					to: directory.appendingPathComponent(
						"\(name)-expected.sem"),
					atomically: true, encoding: .utf8)
				let bytes = try Encoder.encodeJPEG(transcode)
				try Data(bytes).write(
					to: directory.appendingPathComponent(
						"\(name)-optimized.jxl"))
			}
			return
		}
		let directory = URL(fileURLWithPath: try #require(checkPath), isDirectory: true)
		for name in [
			"small_444", "cfl_endpoint_444", "cfl_tile_65x8", "small_422",
			"hopper_gray_odd",
		] {
			let expected = try SemanticDump(
				parsing: String(
					contentsOf: directory.appendingPathComponent(
						"\(name)-expected.sem"),
					encoding: .utf8))
			for suffix in ["optimized"] {
				let actual = try SemanticDump(
					parsing: String(
						contentsOf: directory.appendingPathComponent(
							"\(name)-\(suffix).cfl.sem"),
						encoding: .utf8))
				#expect(
					actual.fields["jpeg_cfl.map_size"]
						== expected.fields["jpeg_cfl.map_size"])
				#expect(
					actual.fields["jpeg_cfl.ytox_map"]
						== expected.fields["jpeg_cfl.ytox_map"])
				#expect(
					actual.fields["jpeg_cfl.ytob_map"]
						== expected.fields["jpeg_cfl.ytob_map"])
				#expect(
					actual.fields[
						"jpeg_context.reconstructed_coefficients_exact"]
						== .integers([1]))
			}
		}
	}
}
