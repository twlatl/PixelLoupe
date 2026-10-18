import Foundation
import Testing
@testable import PixelLoupe

@Suite("Lua table parser")
struct LuaTableParserTests {
    private func parse(_ text: String) throws -> LuaValue {
        try LuaTableParser.parse(text)
    }

    @Test("Parses scalars, keyed entries and the name prefix")
    func scalars() throws {
        let value = try parse(#"s = { Exposure2012 = 0.35, Name = "Bright", Enabled = true, Off = false }"#)
        #expect(value["Exposure2012"]?.number == 0.35)
        #expect(value["Name"]?.string == "Bright")
        #expect(value["Enabled"]?.bool == true)
        #expect(value["Off"]?.bool == false)
        #expect(try parse("{ a = 1 }") == (try parse("s = { a = 1 }")))
    }

    @Test("Parses nested tables with array and hash parts")
    func nested() throws {
        let value = try parse("""
            s = {
                ToneCurvePV2012 = { 0, 0, 128, 140, 255, 255, },
                Group = { inner = { deep = { 1, 2, { 3 } } }, name = "x" },
            }
            """)
        let curve = try #require(value["ToneCurvePV2012"]?.table)
        #expect(curve.array.compactMap(\.int) == [0, 0, 128, 140, 255, 255])
        #expect(curve.hash.isEmpty)
        let deep = try #require(value["Group"]?["inner"]?["deep"]?.table)
        #expect(deep.array.count == 3)
        #expect(deep.array[2].table?.array.first?.int == 3)
        #expect(value["Group"]?["name"]?.string == "x")
    }

    @Test("Handles string escapes")
    func escapes() throws {
        let value = try parse(#"{ a = "quote \" and \\ slash", b = "line\nbreak\ttab", c = 'single \'q\'', d = "\65\066\x43", e = "é ü 日本" }"#)
        #expect(value["a"]?.string == #"quote " and \ slash"#)
        #expect(value["b"]?.string == "line\nbreak\ttab")
        #expect(value["c"]?.string == "single 'q'")
        #expect(value["d"]?.string == "ABC")
        #expect(value["e"]?.string == "é ü 日本")
    }

    @Test("Handles negative, exponent, decimal and hex numbers")
    func numbers() throws {
        let value = try parse("{ a = -1, b = 1e3, c = -2.5E-2, d = .5, e = 0x1F, f = -0x10, g = 12., h = +3, i = -0.0004 }")
        #expect(value["a"]?.number == -1)
        #expect(value["b"]?.number == 1000)
        #expect(value["c"]?.number == -0.025)
        #expect(value["d"]?.number == 0.5)
        #expect(value["e"]?.number == 31)
        #expect(value["f"]?.number == -16)
        #expect(value["g"]?.number == 12)
        #expect(value["h"]?.number == 3)
        #expect(value["i"]?.number == -0.0004)
        #expect(value["a"]?.int == -1)
        #expect(value["c"]?.int == nil)
    }

    @Test("Handles empty tables and separators")
    func empty() throws {
        #expect(try parse("{}") == .table(LuaTable()))
        #expect(try parse("s = {\n}\n") == .table(LuaTable()))
        let value = try parse("{ a = {}, b = { }, 1; 2; 3, }")
        #expect(value["a"]?.table?.isEmpty == true)
        #expect(value["b"]?.table?.isEmpty == true)
        #expect(value.table?.array.compactMap(\.int) == [1, 2, 3])
    }

    @Test("Handles bracketed keys, long strings, comments and nil")
    func miscellany() throws {
        let value = try parse("""
            { -- a comment
              ["quoted key"] = 1, [7] = "seven", --[[ block
              comment ]] text = [[long
            string]], gone = nil, [=[x]=], keep = 2 }
            """)
        #expect(value["quoted key"]?.int == 1)
        #expect(value["7"]?.string == "seven")
        #expect(value["text"]?.string == "long\nstring")
        #expect(value["gone"] == nil)
        #expect(value["keep"]?.int == 2)
        #expect(value.table?.array == [.string("x")])
    }

    @Test("Parses a real smart-collection rule")
    func smartCollectionRule() throws {
        let value = try parse("""
            s = {
            	{
            		criteria = "labelColor",
            		operation = "==",
            		value = 1,
            	},
            	{
            		criteria = "captureTime",
            		operation = "in",
            		value = "2020-01-01",
            		value2 = "2020-12-31",
            	},
            	combine = "intersect",
            }
            """)
        let rules = try #require(value.table)
        #expect(rules["combine"]?.string == "intersect")
        #expect(rules.array.count == 2)
        #expect(rules.array[0]["criteria"]?.string == "labelColor")
        #expect(rules.array[0]["value"]?.int == 1)
        #expect(rules.array[1]["value2"]?.string == "2020-12-31")
    }

    @Test("Parses a real develop-settings sample with a local adjustment")
    func developSettings() throws {
        let value = try parse("""
            s = { AutoGrayscaleMix = false,
            AutoLateralCA = 0,
            CameraProfile = "Adobe Standard",
            CropAngle = -1.5,
            Exposure2012 = 0.35,
            GrainSize = 25,
            ProcessVersion = "15.4",
            ToneCurvePV2012 = { 0, 0, 255, 255, },
            ToneCurvePV2012Red = { 0, 0, 64, 70, 255, 255, },
            WhiteBalance = "As Shot",
            MaskGroupBasedCorrections = {
            	{
            		CorrectionAmount = 1,
            		CorrectionMasks = {
            			{
            				What = "Mask/Image",
            				MaskValue = 1,
            				Gesture = {
            					{ Flow = 1, Pressure = 0.5, Radius = 0.04, X = 0.25, Y = 0.5e-1 },
            				},
            			},
            		},
            		LocalExposure2012 = 0.5,
            		What = "Correction",
            	},
            },
            }
            """)
        #expect(value["Exposure2012"]?.number == 0.35)
        #expect(value["CropAngle"]?.number == -1.5)
        #expect(value["ProcessVersion"]?.string == "15.4")
        let group = try #require(value["MaskGroupBasedCorrections"]?.table?.array.first)
        #expect(group["LocalExposure2012"]?.number == 0.5)
        let gesture = try #require(group["CorrectionMasks"]?.table?.array.first?["Gesture"]?.table?.array.first)
        #expect(gesture["Y"]?.number == 0.05)
    }

    @Test("Reports errors with an offset instead of crashing")
    func errors() {
        for text in ["", "{", "{ a = }", "{ a = 1 b = 2 }", #"{ a = "open }"#, "{ a = 1 } extra", "{ a = 0x }", "{ a = foo }", "{ [1 = 2 }"] {
            #expect(throws: LuaParseError.self) { try LuaTableParser.parse(text) }
        }
        let deep = String(repeating: "{", count: 500) + String(repeating: "}", count: 500)
        #expect(throws: LuaParseError.self) { try LuaTableParser.parse(deep) }
    }

    @Test("Parses on a background executor")
    func background() async throws {
        let value = try await LuaTableParser.parseInBackground("s = { a = 1 }")
        #expect(value["a"]?.int == 1)
    }

    @Test("Parses 20,000 settings blocks quickly")
    func throughput() throws {
        let sample = """
            s = { AutoGrayscaleMix = false, AutoLateralCA = 0, Blacks2012 = 0, CameraProfile = "Embedded", Contrast2012 = 0,
            Exposure2012 = 0.35, Highlights2012 = -20, ProcessVersion = "11.0", Saturation = 0, Shadows2012 = 0, Temperature = 5200,
            ToneCurvePV2012 = { 0, 0, 255, 255, }, Vibrance = 0, WhiteBalance = "As Shot", Whites2012 = 0 }
            """
        let started = ContinuousClock.now
        for _ in 0..<20_000 { _ = try LuaTableParser.parse(sample) }
        #expect(ContinuousClock.now - started < .seconds(5))
    }
}
