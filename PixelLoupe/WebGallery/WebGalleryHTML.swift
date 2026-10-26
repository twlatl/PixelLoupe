import Foundation

/// The web gallery's HTML pages, stylesheet and scripts. The preview and the generated folder are
/// written from the same strings, so what the window shows is what the folder holds.
///
/// Each photo gets a square cell, fitted inside it at its own aspect ratio, with its caption
/// underneath, in a grid of up to `columns` across (fewer on a narrow screen).
nonisolated enum WebGalleryHTML {
    static let stylesheetName = "gallery.css"
    static let thumbnailFolder = "images/thumbs"
    static let largeFolder = "images/large"
    /// Every photo's large image and caption, for the lightbox to step through the whole gallery.
    static let photosScriptName = "photos.js"
    /// The lightbox.
    static let scriptName = "gallery.js"

    /// Narrower than this (in CSS pixels), the grid shows at most two columns; narrower than
    /// `singleColumnWidth`, one.
    static let narrowWidth = 700
    static let singleColumnWidth = 400

    /// The file name of photo `index` (0-based) of `count`: "001.jpg", numbered so they sort in order
    /// and so original file names aren't published.
    static func imageName(index: Int, count: Int) -> String {
        let digits = max(3, String(max(count, 1)).count)
        let number = String(index + 1)
        return String(repeating: "0", count: max(0, digits - number.count)) + number + ".jpg"
    }

    /// The photo an image name names (the reverse of ``imageName(index:count:)``).
    static func index(ofImageNamed name: String) -> Int? {
        guard name.hasSuffix(".jpg"), let number = Int(name.dropLast(4)), number >= 1 else { return nil }
        return number - 1
    }

    // MARK: Pages

    /// Page `page` of the gallery. `sourceName` titles it when there's no headline. The Head and Body
    /// text goes in only with `includesCustomCode` (the preview leaves it out, so a pasted analytics
    /// tag doesn't run with every change).
    static func page(_ page: Int, photos: [ContactSheetPhoto], settings: WebGallerySettings, sourceName: String,
                     includesCustomCode: Bool = true) -> String {
        let pages = WebGalleryPages(photoCount: photos.count, photosPerPage: settings.photosPerPage)
        let headline = settings.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = settings.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = settings.email.trimmingCharacters(in: .whitespacesAndNewlines)
        var title = headline.isEmpty ? sourceName : headline
        if pages.count > 1 { title += " (\(page + 1) of \(pages.count))" }
        let language = Locale.current.language.languageCode?.identifier ?? "en"

        var html = """
        <!DOCTYPE html>
        <html lang="\(escape(language))">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="generator" content="PixelLoupe">
        <title>\(escape(title))</title>
        <link rel="stylesheet" href="\(stylesheetName)">

        """
        if includesCustomCode { html += customCode(settings.headHTML) }
        html += "</head>\n<body>\n"
        if !headline.isEmpty || !description.isEmpty || !email.isEmpty {
            html += "<header>\n"
            if !headline.isEmpty { html += "<h1>\(escape(headline))</h1>\n" }
            if !description.isEmpty { html += "<p class=\"description\">\(escape(description))</p>\n" }
            if !email.isEmpty { html += "<p class=\"email\">\(emailLink(email))</p>\n" }
            html += "</header>\n"
        }

        var gridClasses = ["grid"]
        if settings.showsBorder { gridClasses.append("border") }
        if settings.showsShadow { gridClasses.append("shadow") }
        html += "<main class=\"\(gridClasses.joined(separator: " "))\">\n"
        for index in pages.photos(onPage: page) {
            html += cell(index, photo: photos[index], count: photos.count, settings: settings)
        }
        html += "</main>\n"
        html += navigation(page, pages: pages, showsNumbers: settings.showsPageNumbers)
        html += "<script src=\"\(photosScriptName)\"></script>\n<script src=\"\(scriptName)\"></script>\n"
        if includesCustomCode { html += customCode(settings.bodyHTML) }
        html += "</body>\n</html>\n"
        return html
    }

    private static func cell(_ index: Int, photo: ContactSheetPhoto, count: Int, settings: WebGallerySettings) -> String {
        let name = imageName(index: index, count: count)
        let caption = settings.showsCaption ? photo.caption(settings.captionField) : ""
        let alt = alt(index, photo: photo)
        // The size attributes give the browser the photo's shape before the image arrives, so the
        // grid doesn't jump as thumbnails load. Width / height of 0 means unknown: drawn landscape.
        let aspect = photo.aspect > 0 ? photo.aspect : 1.5
        let width = aspect >= 1 ? 800 : Int((800 * aspect).rounded())
        let height = aspect >= 1 ? Int((800 / aspect).rounded()) : 800
        var html = "<figure id=\"\(index + 1)\">\n"
        // A plain link to the large image, which the lightbox takes over (it still works without JavaScript).
        html += "<div class=\"cell\"><a href=\"\(largeFolder)/\(name)\" data-photo=\"\(index)\">"
        html += "<img class=\"\(aspect >= 1 ? "landscape" : "portrait")\" src=\"\(thumbnailFolder)/\(name)\" "
        html += "width=\"\(width)\" height=\"\(height)\" alt=\"\(escape(alt))\" loading=\"lazy\" decoding=\"async\"></a></div>\n"
        if settings.showsCaption {
            // An empty caption still takes its line, so the rows stay even.
            html += "<figcaption>\(caption.isEmpty ? "&nbsp;" : escape(caption))</figcaption>\n"
        }
        html += "</figure>\n"
        return html
    }

    /// The user's Head or Body text exactly as typed (it's theirs to get right), on lines of its own.
    private static func customCode(_ code: String) -> String {
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        return code.hasSuffix("\n") ? code : code + "\n"
    }

    /// A `mailto:` link to `address`, every character of it written as a numeric character
    /// reference: a browser reads it as usual (a click opens the mail app), but an address harvester
    /// looking for "@" in the page source doesn't.
    static func emailLink(_ address: String) -> String {
        "<a href=\"\(entities("mailto:" + address))\">\(entities(address))</a>"
    }

    /// `text` as numeric character references (`&#109;&#97;…`).
    static func entities(_ text: String) -> String {
        text.unicodeScalars.map { "&#\($0.value);" }.joined()
    }

    /// The alt text describes the photo even when the caption shows something else; the file name is
    /// published only when it's the caption.
    private static func alt(_ index: Int, photo: ContactSheetPhoto) -> String {
        photo.title ?? photo.caption ?? "Photo \(index + 1)"
    }

    /// "‹ Previous · 1 2 3 · Next ›" under the grid; nothing for a single page.
    private static func navigation(_ page: Int, pages: WebGalleryPages, showsNumbers: Bool) -> String {
        guard pages.count > 1 else { return "" }
        var items: [String] = []
        if page > 0 {
            items.append("<a rel=\"prev\" href=\"\(WebGalleryPages.fileName(ofPage: page - 1))\">‹ Previous</a>")
        } else {
            items.append("<span class=\"disabled\">‹ Previous</span>")
        }
        if showsNumbers {
            for link in pages.numberedLinks(around: page) {
                guard let link else {
                    items.append("<span class=\"gap\">…</span>")
                    continue
                }
                items.append(link == page
                    ? "<span aria-current=\"page\">\(link + 1)</span>"
                    : "<a href=\"\(WebGalleryPages.fileName(ofPage: link))\">\(link + 1)</a>")
            }
        }
        if page < pages.count - 1 {
            items.append("<a rel=\"next\" href=\"\(WebGalleryPages.fileName(ofPage: page + 1))\">Next ›</a>")
        } else {
            items.append("<span class=\"disabled\">Next ›</span>")
        }
        return "<nav class=\"pages\" aria-label=\"Pages\">\n\(items.joined(separator: "\n"))\n</nav>\n"
    }

    // MARK: Stylesheet

    static func stylesheet(settings: WebGallerySettings) -> String {
        let columns = min(max(settings.columns, WebGallerySettings.columnRange.lowerBound), WebGallerySettings.columnRange.upperBound)
        let border = ContactSheetLayout.borderFraction * 100
        return """
        :root {
          --text: \(css(settings.textColor));
          --background: \(css(settings.backgroundColor));
          --columns: \(columns);
        }
        @media (max-width: \(narrowWidth)px) { :root { --columns: \(min(columns, 2)); } }
        @media (max-width: \(singleColumnWidth)px) { :root { --columns: 1; } }

        * { box-sizing: border-box; }
        html { background: var(--background); color: var(--text); }
        body {
          margin: 0 auto;
          padding: 36px 24px;
          max-width: 1600px;
          font: 15px/1.4 -apple-system, BlinkMacSystemFont, "Helvetica Neue", Helvetica, Arial, sans-serif;
        }
        a { color: inherit; }
        header { margin-bottom: 24px; }
        h1 { margin: 0 0 4px; font-size: 1.6em; font-weight: 600; }
        .description { margin: 0; white-space: pre-line; }
        .email { margin: 4px 0 0; }

        .grid {
          display: grid;
          grid-template-columns: repeat(var(--columns), minmax(0, 1fr));
          gap: 16px;
        }
        figure { margin: 0; min-width: 0; }
        .cell {
          aspect-ratio: 1;
          display: flex;
          align-items: center;
          justify-content: center;
        }
        .cell a {
          display: flex;
          align-items: center;
          justify-content: center;
          width: 100%;
          height: 100%;
        }
        .cell img { display: block; object-fit: contain; }
        .cell img.landscape { width: 100%; height: auto; }
        .cell img.portrait { height: 100%; width: auto; }
        .border .cell img { padding: \(String(format: "%g", border))%; background: #fff; }
        .shadow .cell img { box-shadow: 0 2px 8px rgba(0, 0, 0, 0.35); }
        figcaption {
          margin-top: 4px;
          font-size: 0.75em;
          text-align: center;
          white-space: nowrap;
          overflow: hidden;
          text-overflow: ellipsis;
        }

        .pages {
          display: flex;
          flex-wrap: wrap;
          justify-content: center;
          gap: 4px 12px;
          margin-top: 32px;
        }
        .pages a { text-decoration: none; }
        .pages a:hover { text-decoration: underline; }
        .pages [aria-current] { font-weight: 700; }
        .pages .disabled { opacity: 0.4; }

        html.lightbox-open { overflow: hidden; }
        .lightbox {
          position: fixed;
          inset: 0;
          z-index: 10;
          display: flex;
          align-items: center;
          justify-content: center;
          background: rgba(0, 0, 0, 0.92);
          color: #fff;
        }
        .lightbox[hidden], .lightbox [hidden] { display: none; }
        .lightbox figure {
          margin: 0;
          display: flex;
          flex-direction: column;
          align-items: center;
        }
        .lightbox img {
          display: block;
          max-width: calc(100vw - 128px);
          max-height: calc(100vh - 96px);
          object-fit: contain;
        }
        .lightbox figcaption { margin-top: 8px; font-size: 0.9em; text-align: center; }
        .lightbox button {
          position: absolute;
          padding: 8px 16px;
          border: 0;
          background: none;
          color: inherit;
          font: 40px/1 -apple-system, BlinkMacSystemFont, "Helvetica Neue", Helvetica, Arial, sans-serif;
          opacity: 0.7;
          cursor: pointer;
        }
        .lightbox button:hover, .lightbox button:focus-visible { opacity: 1; }
        .lightbox .close { top: 8px; right: 8px; }
        .lightbox .previous, .lightbox .next { top: 50%; transform: translateY(-50%); }
        .lightbox .previous { left: 8px; }
        .lightbox .next { right: 8px; }
        @media (max-width: \(narrowWidth)px) {
          .lightbox img { max-width: 100vw; max-height: calc(100vh - 64px); }
          .lightbox .previous, .lightbox .next { top: auto; bottom: 8px; transform: none; }
        }

        """
    }

    // MARK: Scripts

    /// One photo in `photos.js`.
    private struct ScriptPhoto: Encodable {
        let large: String
        let alt: String
        let caption: String
        /// The page it's on.
        let page: String
    }

    /// `photos.js`: every photo's large image, alt text, caption (when captions show) and page.
    static func photosScript(photos: [ContactSheetPhoto], settings: WebGallerySettings) -> String {
        let pages = WebGalleryPages(photoCount: photos.count, photosPerPage: settings.photosPerPage)
        let entries = photos.indices.map { index in
            ScriptPhoto(large: "\(largeFolder)/\(imageName(index: index, count: photos.count))",
                        alt: alt(index, photo: photos[index]),
                        caption: settings.showsCaption ? photos[index].caption(settings.captionField) : "",
                        page: WebGalleryPages.fileName(ofPage: index / pages.photosPerPage))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = (try? encoder.encode(entries)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return "window.galleryPhotos = \(json);\n"
    }

    /// `gallery.js`, the lightbox. Clicking a photo shows its large image over the page; Previous and
    /// Next (the arrows, ← and →, or a swipe) step through every photo in the gallery, not just the
    /// page's; Esc, the close button or a click beside the photo closes it. The address follows the
    /// photo (`#7`), so a photo can be linked to, and closing on another page's photo goes to that page.
    static let script = #"""
    (function () {
      "use strict";
      var photos = window.galleryPhotos || [];
      if (!photos.length) return;
      var CLOSED = "pixelloupe-gallery-closed";
      var box, image, caption, previous, next, closeButton;
      var current = -1, opener = null, touchX = null;

      function page() {
        return decodeURIComponent(location.pathname.split("/").pop() || "index.html");
      }

      function remember(key, value) {
        try { value === null ? sessionStorage.removeItem(key) : sessionStorage.setItem(key, value); } catch (error) {}
      }

      function recalled(key) {
        try { return sessionStorage.getItem(key); } catch (error) { return null; }
      }

      function button(className, label, text, action) {
        var element = document.createElement("button");
        element.type = "button";
        element.className = className;
        element.setAttribute("aria-label", label);
        element.textContent = text;
        element.addEventListener("click", function (event) {
          event.stopPropagation();
          action();
        });
        box.appendChild(element);
        return element;
      }

      function build() {
        box = document.createElement("div");
        box.className = "lightbox";
        box.hidden = true;
        box.setAttribute("role", "dialog");
        box.setAttribute("aria-modal", "true");
        box.setAttribute("aria-label", "Photo");
        var figure = document.createElement("figure");
        image = document.createElement("img");
        caption = document.createElement("figcaption");
        figure.appendChild(image);
        figure.appendChild(caption);
        box.appendChild(figure);
        closeButton = button("close", "Close", "\u00D7", close);
        previous = button("previous", "Previous photo", "\u2039", function () { step(-1); });
        next = button("next", "Next photo", "\u203A", function () { step(1); });
        // A click beside the photo closes it; one on the photo doesn't.
        box.addEventListener("click", function (event) {
          if (event.target !== image && event.target !== caption) close();
        });
        box.addEventListener("touchstart", function (event) {
          touchX = event.touches.length === 1 ? event.touches[0].clientX : null;
        }, { passive: true });
        box.addEventListener("touchend", function (event) {
          if (touchX === null) return;
          var distance = event.changedTouches[0].clientX - touchX;
          touchX = null;
          if (Math.abs(distance) > 50) step(distance < 0 ? 1 : -1);
        });
        document.body.appendChild(box);
      }

      function preload(index) {
        if (index >= 0 && index < photos.length) new Image().src = photos[index].large;
      }

      function show(index) {
        if (index < 0 || index >= photos.length) return;
        if (!box) build();
        if (current < 0) opener = document.activeElement;
        current = index;
        var photo = photos[index];
        image.src = photo.large;
        image.alt = photo.alt;
        caption.textContent = photo.caption;
        caption.hidden = !photo.caption;
        previous.hidden = index === 0;
        next.hidden = index === photos.length - 1;
        preload(index + 1);
        preload(index - 1);
        history.replaceState(null, "", "#" + (index + 1));
        document.documentElement.classList.add("lightbox-open");
        if (box.hidden) {
          box.hidden = false;
          closeButton.focus();
        }
      }

      function step(by) {
        if (current >= 0) show(current + by);
      }

      function close() {
        if (current < 0) return;
        var index = current, photo = photos[index];
        current = -1;
        box.hidden = true;
        document.documentElement.classList.remove("lightbox-open");
        if (photo.page !== page()) {
          // Its page, scrolled to it, without opening it again there.
          remember(CLOSED, String(index + 1));
          location.href = photo.page + "#" + (index + 1);
          return;
        }
        history.replaceState(null, "", location.pathname + location.search);
        var link = document.querySelector('a[data-photo="' + index + '"]');
        if (link) {
          link.scrollIntoView({ block: "nearest" });
          link.focus();
        } else if (opener && opener.focus) {
          opener.focus();
        }
      }

      document.addEventListener("click", function (event) {
        var link = event.target.closest && event.target.closest("a[data-photo]");
        if (!link || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
        event.preventDefault();
        show(Number(link.getAttribute("data-photo")));
      });

      document.addEventListener("keydown", function (event) {
        if (current < 0) return;
        if (event.key === "Escape") close();
        else if (event.key === "ArrowLeft") step(-1);
        else if (event.key === "ArrowRight") step(1);
        else return;
        event.preventDefault();
      });

      // Keep focus in the lightbox while it's open.
      document.addEventListener("focusin", function (event) {
        if (current >= 0 && box && !box.contains(event.target)) closeButton.focus();
      });

      function openFromAddress() {
        var match = /^#(\d+)$/.exec(location.hash);
        if (!match) return;
        if (recalled(CLOSED) === match[1]) {
          remember(CLOSED, null);
          return;
        }
        show(Number(match[1]) - 1);
      }

      window.addEventListener("hashchange", openFromAddress);
      openFromAddress();
    })();

    """#

    // MARK: Helpers

    /// `value` with HTML's special characters escaped, for text and attribute values.
    static func escape(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&#39;"
            default: escaped.append(character)
            }
        }
        return escaped
    }

    /// "#1a2b3c".
    static func css(_ color: WebGallerySettings.Color) -> String {
        func byte(_ component: Double) -> Int { Int((min(max(component, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(color.red), byte(color.green), byte(color.blue))
    }
}
