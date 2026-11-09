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

        /// A `crs:` element being read, or an `rdf:li` item of one. Masks nest these: a sequence of
        /// corrections, each a description with its own sequence of mask shapes.
        private struct Frame {
            var key: String?
            /// Attributes, of the element itself or of a description inside it.
            var table = LuaTable()
            var items: [LuaValue] = []
            var text = ""
            /// Its items are alternatives (`rdf:Alt`, such as a localized name), not a list.
            var isAlternative = false
        }

        private var stack: [Frame] = []

        private static func settings(_ attributes: [String: String]) -> [(String, LuaValue)] {
            attributes.filter { $0.key.hasPrefix("crs:") }.map { (String($0.key.dropFirst(4)), XMPDevelopSettings.value(for: $0.value)) }
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if elementName == "rdf:Description" {
                // Inside a setting or an item, the attributes belong to it; otherwise they're settings.
                for (key, value) in Self.settings(attributes) {
                    if stack.isEmpty { table.hash[key] = value } else { stack[stack.count - 1].table.hash[key] = value }
                }
            } else if elementName.hasPrefix("crs:") {
                var frame = Frame(key: String(elementName.dropFirst(4)))
                for (key, value) in Self.settings(attributes) { frame.table.hash[key] = value }
                stack.append(frame)
            } else if elementName == "rdf:li", !stack.isEmpty {
                var frame = Frame()
                for (key, value) in Self.settings(attributes) { frame.table.hash[key] = value }
                stack.append(frame)
            } else if elementName == "rdf:Alt", !stack.isEmpty {
                stack[stack.count - 1].isAlternative = true
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if !stack.isEmpty { stack[stack.count - 1].text += string }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            let isItem = elementName == "rdf:li"
            guard isItem || elementName.hasPrefix("crs:"), let frame = stack.popLast() else { return }
            if isItem {
                guard !stack.isEmpty else { return }
                if !frame.table.isEmpty {
                    stack[stack.count - 1].items.append(.table(frame.table))
                } else {
                    // A curve point "x, y" is two numbers; anything else is one value.
                    let parts = frame.text.split(separator: ",").map { String($0) }
                    if parts.count == 2 {
                        stack[stack.count - 1].items.append(contentsOf: parts.map { XMPDevelopSettings.value(for: $0) })
                    } else {
                        stack[stack.count - 1].items.append(XMPDevelopSettings.value(for: frame.text))
                    }
                }
                return
            }
            guard let key = frame.key else { return }
            let value: LuaValue
            if !frame.items.isEmpty {
                // Within a setting (a look's group), a localized name is its text; a list stays a list.
                value = !stack.isEmpty && frame.isAlternative ? frame.items[0] : .table(LuaTable(array: frame.items))
            } else if !frame.table.isEmpty {
                value = .table(frame.table)
            } else if !frame.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                value = XMPDevelopSettings.value(for: frame.text)
            } else {
                return
            }
            if stack.isEmpty { table.hash[key] = value } else { stack[stack.count - 1].table.hash[key] = value }
        }
    }
}
