//
//  CodeEditor.swift
//
//  Created by Manuel M T Chakravarty on 23/08/2020.
//
//  SwiftUI 'CodeEditor' view

import SwiftUI


/// SwiftUI code editor based on TextKit.
///
/// SwiftUI `Environment`:
/// * Environment value `codeEditorTheme`: determines the code highlighting theme to use
/// * Text-related values: affect the rendering of message views
///
public struct CodeEditor {

  /// Specification of the editor layout.
  ///
  public struct LayoutConfiguration: Equatable {

    /// Show the minimap if possible. (Currently only supported on macOS.)
    ///
    public let showMinimap: Bool

    /// Creates a layout configuration.
    ///
    /// - Parameter showMinimap: Whether to show the minimap if possible. It may not be possible on all supported OSes.
    ///
    public init(showMinimap: Bool) {
      self.showMinimap = showMinimap
    }

    public static let standard = LayoutConfiguration(showMinimap: true)
  }

  /// Specification of a text editing location; i.e., text selection and scroll position.
  ///
  public struct Location {

    /// Specification of a list of selection ranges.
    ///
    /// * A range with a zero length indicates an insertion point.
    /// * An empty array, corresponds to an insertion point at position 0.
    /// * On iOS, this can only always be one range.
    ///
    public var selections: [NSRange]

    /// The editor vertical scroll position. The value is between 0 and 1, which represent the completely scrolled up
    /// and down position, respectively.
    ///
    public var verticalScrollFraction: CGFloat

    public init(selections: [NSRange], verticalScrollFraction: CGFloat) {
      self.selections             = selections
      self.verticalScrollFraction = verticalScrollFraction
    }

    public init() {
      self.init(selections: [NSRange(location: 0, length: 0)], verticalScrollFraction: 0)
    }
  }

  let language: LanguageConfiguration
  let layout  : LayoutConfiguration

  @Binding private var text:     String
  private var location: Binding<Location>?
  @Binding private var messages: Set<Located<Message>>

  /// Creates a fully configured code editor.
  ///
  /// - Parameters:
  ///   - text: Binding to the edited text.
  ///   - location: Optional binding to the current edit location.
  ///   - messages: Binding to the messages reported at the appropriate lines of the edited text. NB: Messages
  ///               processing and display is relatively expensive. Hence, there should only be a limited number of
  ///               simultaneous messages and they shouldn't change to frequently.
  ///   - language: Language configuration for highlighting and similar.
  ///   - layout: Layout configuration determining the visible elements of the editor view.
  ///
  public init(text:     Binding<String>,
              location: Binding<Location>? = nil,
              messages: Binding<Set<Located<Message>>>,
              language: LanguageConfiguration = .none,
              layout:   LayoutConfiguration = .standard)
  {
    self._text     = text
    self.location = location
    self._messages = messages
    self.language  = language
    self.layout    = layout
  }

  public class _Coordinator {
    @Binding var text: String

    /// This is the last observed value of `messages`, to enable us to compute the difference in the next update.
    ///
    fileprivate var lastMessages: Set<Located<Message>> = Set()

      init(_ text: Binding<String>) {
          self._text = text
    }
  }
}

#if os(iOS)

// MARK: -
// MARK: UIKit version

extension CodeEditor: UIViewRepresentable {
  public func makeUIView(context: Context) -> UITextView {
    let codeView = CodeView(frame: CGRect(x: 0, y: 0, width: 100, height: 40),
                            with: language,
                            viewLayout: layout,
                            theme: context.environment.codeEditorTheme)

    codeView.text = text
    if let delegate = codeView.delegate as? CodeViewDelegate {
      delegate.textDidChange      = context.coordinator.textDidChange
      delegate.selectionDidChange = { textView in
        selectionDidChange(textView)
        DispatchQueue.main.async {
            location?.wrappedValue.selections = [textView.selectedRange]
        }
      }
      delegate.didScroll = { scrollView in
        DispatchQueue.main.async {
          location?.wrappedValue.verticalScrollFraction = scrollView.verticalScrollFraction
        }
      }
    }
    codeView.selectedRange = location?.wrappedValue.selections.first ?? NSRange(location: 0, length: 0)

    // We can't set the scroll position right away as the views are not properly sized yet. Thus, this needs to be
    // delayed.
    // TODO: The scroll fraction assignment still happens to soon if the initialisisation takes a long time, because we loaded a large file. It be better if we could deterministically determine when initialisation is entirely finished and then set the scroll fraction at that point.
    DispatchQueue.main.async {
      codeView.verticalScrollFraction = location?.wrappedValue.verticalScrollFraction
    }

    // Report the initial message set
    DispatchQueue.main.async { updateMessages(in: codeView, with: context) }

    return codeView
  }

  public func updateUIView(_ textView: UITextView, context: Context) {
    guard let codeView = textView as? CodeView else { return }
    
    let theme     = context.environment.codeEditorTheme,
        selection = location.selections.first ?? NSRange(location: 0, length: 0)

    updateMessages(in: codeView, with: context)
    if text != textView.text { textView.text = text }  // Hoping for the string comparison fast path...
    if selection != codeView.selectedRange { codeView.selectedRange = selection }
    if location.verticalScrollFraction - textView.verticalScrollFraction > 0.0001 {
      textView.verticalScrollFraction = location.verticalScrollFraction
    }
    if theme.id != codeView.theme.id { codeView.theme = theme }
    if layout != codeView.viewLayout { codeView.viewLayout = layout }
  }

  public func makeCoordinator() -> Coordinator {
    return Coordinator($text, location: $location)
  }

  public final class Coordinator: _Coordinator {

    func textDidChange(_ textView: UITextView) {
      self.text = textView.text
        location.selections = [textView.selectedRange]
    }

  }
}

#elseif os(macOS)

// MARK: -
// MARK: AppKit version

extension CodeEditor: NSViewRepresentable {
  public func makeNSView(context: Context) -> NSScrollView {

    // Set up scroll view
    let scrollView = NSScrollView(frame: CGRect(x: 0, y: 0, width: 100, height: 40))
    scrollView.borderType          = .noBorder
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalRuler  = false
    scrollView.autoresizingMask    = [.width, .height]

    // Set up text view with gutter
    let codeView = CodeView(frame: CGRect(x: 0, y: 0, width: 100, height: 40),
                            with: language,
                            viewLayout: layout,
                            theme: context.environment.codeEditorTheme)
    codeView.isVerticallyResizable   = true
    codeView.isHorizontallyResizable = false
    codeView.autoresizingMask        = .width

    // Embed text view in scroll view
    scrollView.documentView = codeView

    codeView.string = text
    if let delegate = codeView.delegate as? CodeViewDelegate {
      delegate.textDidChange      = context.coordinator.textDidChange
      delegate.selectionDidChange = { textView in
        selectionDidChange(textView)
        DispatchQueue.main.async {
            location?.wrappedValue.selections = textView.selectedRanges.map{ $0.rangeValue }
        }
      }
    }
      if let selections = location?.wrappedValue.selections {
        codeView.selectedRanges = selections.map{ NSValue(range: $0) }
      }

    // We can't set the scroll position right away as the views are not properly sized yet. Thus, this needs to be
    // delayed.
    // TODO: The scroll fraction assignment still happens to soon if the initialisisation takes a long time, because we loaded a large file. It be better if we could deterministically determine when initialisation is entirely finished and then set the scroll fraction at that point.
    DispatchQueue.main.async {
        if let verticalScrollFraction = location?.wrappedValue.verticalScrollFraction {
          scrollView.verticalScrollFraction = verticalScrollFraction
        }
    }

    // The minimap needs to be vertically positioned in dependence on the scroll position of the main code view and
    // we need to keep track of the scroll position.
    context.coordinator.boundsChangedNotificationObserver
      = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView,
                                               queue: .main){ _ in
        DispatchQueue.main.async {
          location?.wrappedValue.verticalScrollFraction = scrollView.verticalScrollFraction
        }
        codeView.adjustScrollPositionOfMinimap()
      }

    // Report the initial message set
    DispatchQueue.main.async { updateMessages(in: codeView, with: context) }

    return scrollView
  }

  public func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let codeView = scrollView.documentView as? CodeView else { return }
    
    let theme                      = context.environment.codeEditorTheme,
        selections                 = location?.wrappedValue.selections.map{ NSValue(range: $0) }

    updateMessages(in: codeView, with: context)
    if text != codeView.string { codeView.string = text }  // Hoping for the string comparison fast path...
    if let selections = selections, selections != codeView.selectedRanges { codeView.selectedRanges = selections }
      if let verticalScrollFraction = location?.wrappedValue.verticalScrollFraction, verticalScrollFraction - scrollView.verticalScrollFraction > 0.0001 {
          scrollView.verticalScrollFraction = verticalScrollFraction
    }
    if theme.id != codeView.theme.id { codeView.theme = theme }
    if layout != codeView.viewLayout { codeView.viewLayout = layout }
  }

  public func makeCoordinator() -> Coordinator {
    return Coordinator($text)
  }

  public final class Coordinator: _Coordinator {
    var boundsChangedNotificationObserver: NSObjectProtocol?

    deinit {
      if let observer = boundsChangedNotificationObserver { NotificationCenter.default.removeObserver(observer) }
    }

    func textDidChange(_ textView: NSTextView) {
      self.text = textView.string
    }
  }
}

#endif


// MARK: -
// MARK: Shared code

extension CodeEditor {
  /// Update messages for a code view in the given context.
  ///
  private func updateMessages(in codeView: CodeView, with context: Context) {
    update(oldMessages: context.coordinator.lastMessages, to: messages, in: codeView)
    context.coordinator.lastMessages = messages
  }

  /// Update the message set of the given code view.
  ///
  private func update(oldMessages: Set<Located<Message>>,
                      to updatedMessages: Set<Located<Message>>,
                      in codeView: CodeView)
  {
    let messagesToAdd    = updatedMessages.subtracting(oldMessages),
        messagesToRemove = oldMessages.subtracting(updatedMessages)

    for message in messagesToRemove { codeView.retract(message: message.entity) }
    for message in messagesToAdd    { codeView.report(message: message) }
  }
}

/// Environment key for the current code editor theme.
///
public struct CodeEditorTheme: EnvironmentKey {
  public static var defaultValue: Theme = Theme.defaultLight
}

extension EnvironmentValues {
  /// The current code editor theme.
  ///
  public var codeEditorTheme: Theme {
    get { self[CodeEditorTheme.self] }
    set { self[CodeEditorTheme.self] = newValue }
  }
}

extension CodeEditor.Location: RawRepresentable {

  public init?(rawValue: String) {

    func parseNSRange(lexeme: String) -> NSRange? {
      let components = lexeme.components(separatedBy: ":")
      guard components.count == 2,
            let location = Int(components[0]),
            let length   = Int(components[1])
      else { return nil }
      return NSRange(location: location, length: length)
    }

    let components = rawValue.components(separatedBy: "|")
    if components.count == 2 {

      selections             = components[0].components(separatedBy: ";").compactMap{ parseNSRange(lexeme: $0) }
      verticalScrollFraction = CGFloat(Double(components[1]) ?? 0)

    } else { self = CodeEditor.Location() }
  }

  public var rawValue: String {
    let selectionsString             = selections.map{ "\($0.location):\($0.length)" }.joined(separator: ";"),
        verticalScrollFractionString = String(describing: verticalScrollFraction)
    return selectionsString + "|" + verticalScrollFractionString
  }
}


// MARK: -
// MARK: Previews

struct CodeEditor_Previews: PreviewProvider {

  static var previews: some View {
    CodeEditor(text: .constant("-- Hello World!"), location: nil, messages: .constant(Set()), language: .haskell)
  }
}
