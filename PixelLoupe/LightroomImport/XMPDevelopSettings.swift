import Foundation

/// Reads Lightroom's develop settings from an XMP sidecar or a preset's XMP (`crs:` attributes and
/// elements) into the same table the catalog's settings text parses to, so the develop mapper can
/// take either. Numbers (`+0.50`), booleans (`True`) and curves (a `rdf:Seq` of `x, y` items) are
/// converted; anything else stays text.
nonisolated enum XMPDevelopSettings {
    static func parse(_ data: Data) -> LuaTable? {
        let parser = Parser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.shouldProcessNamespaces = false
        guard xml.parse(), !parser.table.isEmpty else { return nil }
        return parser.table
    }

    /// An XMP attribute or element value as a Lua value.
    static func value(for text: String) -> LuaValue {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed.lowercased() {
        case "true": return .bool(true)
        case "false": return .bool(false)
        default: break
        }
        if let number = Double(trimmed.hasPrefix("+") ? String(trimmed.dropFirst()) : trimmed) { return .number(number) }
        return .string(trimmed)
    }

    private final class Parser: NSObject, XMLParserDelegate {
        var table = LuaTable()
        /// The `crs:` element being read, with the items of its sequence so far.
        private var element: String?
        private var items: [LuaValue] = []
        /// Attributes of a description nested in the element (a look's name, for example).
        private var nested = LuaTable()
        /// A `crs:` element inside that description (a look's sort name or group): part of the setting.
        private var inner: String?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if elementName == "rdf:Description" {
                for (name, value) in attributes where name.hasPrefix("crs:") {
                    // Inside a settings element, the attributes belong to that setting.
                    if element != nil { nested.hash[String(name.dropFirst(4))] = XMPDevelopSettings.value(for: value) }
                    else { table.hash[String(name.dropFirst(4))] = XMPDevelopSettings.value(for: value) }
                }
            } else if elementName.hasPrefix("crs:") {
                if element != nil {
                    // Belongs to the setting being read; don't start a new one.
                    inner = String(elementName.dropFirst(4))
                    text = ""
                    return
                }
                element = String(elementName.dropFirst(4))
                items = []
                nested = LuaTable()
                text = ""
            } else if elementName == "rdf:li" {
                text = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            if let inner {
                if elementName == "rdf:li", nested.hash[inner] == nil {
                    nested.hash[inner] = XMPDevelopSettings.value(for: text)
                } else if elementName == "crs:\(inner)" {
                    self.inner = nil
                }
                text = ""
                return
            }
            if elementName == "rdf:li", element != nil {
                // A curve point "x, y" is two numbers; anything else is one value.
                let parts = text.split(separator: ",").map { String($0) }
                if parts.count == 2 { items.append(contentsOf: parts.map { XMPDevelopSettings.value(for: $0) }) } else { items.append(XMPDevelopSettings.value(for: text)) }
                text = ""
            } else if elementName.hasPrefix("crs:"), element == String(elementName.dropFirst(4)) {
                let key = String(elementName.dropFirst(4))
                if !items.isEmpty {
                    table.hash[key] = .table(LuaTable(array: items))
                } else if !nested.isEmpty {
                    table.hash[key] = .table(nested)
                } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    table.hash[key] = XMPDevelopSettings.value(for: text)
                }
                element = nil
            }
        }
    }
}
