// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:charcode/charcode.dart';

import 'ast.dart';
import 'document.dart';
import 'emojis.dart';
import 'util.dart';

///Maps an URL (specified in a reference).
///If nothing to change, just return [url].
///It can return null (if not a link), a [String] or a [Link].
typedef String LinkMapper(InlineParser parser, String url);

///The regular expression pattern for HTML entities.
const String htmlEntityPattern = r'&([a-zA-Z0-9]+|#[0-9]+|#[xX][a-fA-F0-9]+);';

/// Parses a link starting at [start] and end at [end] (excludive)
///
/// * [start] - the position of the starting `(`
InlineLink? parseInlineLink(String source, int start) {
  //tomyeh
  final parser = _SimpleParser(source)..pos = start,
      link = LinkSyntax._parseInlineLink(parser);
  if (link != null) link.end = parser.pos + 1;
  return link;
}

/// A simple parser
class _SimpleParser {
  //tomyeh
  /// The string of Markdown being parsed.
  final String source;

  /// The current read position.
  int pos = 0;

  _SimpleParser(this.source);

  bool get isDone => pos == source.length;

  void advanceBy(int length) {
    pos += length;
  }

  int charAt(int index) => source.codeUnitAt(index);
}

const _whitespaces = <int>{$space, $lf, $cr, $ff};

/// Maintains the internal state needed to parse inline span elements in
/// Markdown.
class InlineParser extends _SimpleParser {
  static final List<InlineSyntax> _defaultSyntaxes =
      List<InlineSyntax>.unmodifiable(<InlineSyntax>[
    EmailAutolinkSyntax(),
    AutolinkSyntax(),
    LineBreakSyntax(),
    LinkSyntax(),
    ImageSyntax(),
    // Allow any punctuation to be escaped.
    EscapeSyntax(),
    // "*" surrounded by spaces is left alone.
    TextSyntax(r' \* ', startCharacter: $space),
    // "_" surrounded by spaces is left alone.
    TextSyntax(r' _ ', startCharacter: $space),
    // Parse "**strong**" and "*emphasis*" tags.
    TagSyntax(r'\*+', requiresDelimiterRun: true),
    // Parse "__strong__" and "_emphasis_" tags.
    TagSyntax(r'_+', requiresDelimiterRun: true),
    CodeSyntax(),
    // We will add the LinkSyntax once we know about the specific link resolver.
  ]);

  static final List<InlineSyntax> _htmlSyntaxes =
      List<InlineSyntax>.unmodifiable(<InlineSyntax>[
    // Leave already-encoded HTML entities alone. Ensures we don't turn
    // "&amp;" into "&amp;amp;"
    TextSyntax(r'&[#a-zA-Z0-9]*;', startCharacter: $ampersand),
    // Encode "&".
    TextSyntax(r'&', sub: '&amp;', startCharacter: $ampersand),
    // Encode "<".
    TextSyntax(r'<', sub: '&lt;', startCharacter: $lt),
    // Encode ">".
    TextSyntax(r'>', sub: '&gt;', startCharacter: $gt),
    // We will add the LinkSyntax once we know about the specific link resolver.
  ]);

  /// Similar to [_defaultSyntaxes], but it excludes `_` and hard-line-break,
  /// while including `~~`
  static final simpleSyntaxes = <InlineSyntax>[
    AutolinkSyntax(),
    LinkSyntax(),
    ImageSyntax(),
    // Allow any punctuation to be escaped.
    EscapeSyntax(),
    // "*" surrounded by spaces is left alone.
    TextSyntax(r' \* ', startCharacter: $space),
    // "~" surrounded by spaces is left alone.
    TextSyntax(r' ~ ', startCharacter: $space),
    // Leave already-encoded HTML entities alone. Ensures we don't turn
    // "&amp;" into "&amp;amp;"
    TextSyntax(htmlEntityPattern),
    // Encode "&".
    TextSyntax(r'&', sub: '&amp;'),
    // Encode "<".
    TextSyntax(r'<', sub: '&lt;'),
    // Encode ">". (Google calendar expects it)
    TextSyntax(r'>', sub: '&gt;'),
    // Parse "**strong**" tags.
    // Parse "**strong**" and "*emphasis*" tags.
    TagSyntax(r'\*+', requiresDelimiterRun: true),
    StrikethroughSyntax(),
    CodeSyntax(),
    // We will add the LinkSyntax once we know about the specific link resolver.
  ];

  /// The Markdown document this parser is parsing.
  final Document document;

  final List<InlineSyntax> syntaxes;

  /// Starting position of the last unconsumed text.
  int start = 0;

  final List<TagState> _stack;

  InlineParser(String source, this.document)
      : _stack = <TagState>[],
        syntaxes = <InlineSyntax>[],
        super(source) {
    // User specified syntaxes are the first syntaxes to be evaluated.
    syntaxes.addAll(document.inlineSyntaxes);

    var hasCustomInlineSyntaxes = document.inlineSyntaxes
        .any((s) => !document.extensionSet!.inlineSyntaxes.contains(s));

    // This first RegExp matches plain text to accelerate parsing. It's written
    // so that it does not match any prefix of any following syntaxes. Most
    // Markdown is plain text, so it's faster to match one RegExp per 'word'
    // rather than fail to match all the following RegExps at each non-syntax
    // character position.
    if (hasCustomInlineSyntaxes) {
      // We should be less aggressive in blowing past "words".
      syntaxes.add(TextSyntax(r'[A-Za-z0-9]+(?=\s)'));
    } else {
      syntaxes.add(TextSyntax(r'[ \tA-Za-z0-9]*[A-Za-z0-9](?=\s)'));
    }

    syntaxes.addAll(_defaultSyntaxes);

    if (document.encodeHtml) {
      syntaxes.addAll(_htmlSyntaxes);
    }

    // Custom link resolvers go after the generic text syntax.
    var iterable = <InlineSyntax>[];
    if (document.linkResolver != null)
      iterable.add(LinkSyntax(linkResolver: document.linkResolver!));
    if (document.imageLinkResolver != null)
      iterable.add(ImageSyntax(linkResolver: document.imageLinkResolver!));
    syntaxes.insertAll(1, iterable);
  }

  /// Instantiates with all syntaxes specified in [syntaxes].
  /// It doesn't add any flavor or default syntaxes into it.
  InlineParser.be(String source, this.document, this.syntaxes)
      : _stack = <TagState>[],
        super(source);

  ///The options passed to [document].
  dynamic get options => document.options;

  List<Node> parse() {
    // Make a fake top tag to hold the results.
    _stack.add(TagState(0, 0, null, null));

    while (!isDone) {
      // See if any of the current tags on the stack match.  This takes
      // priority over other possible matches.
      if (_stack.reversed
          .any((state) => state.syntax != null && state.tryMatch(this))) {
        continue;
      }

      // See if the current text matches any defined markdown syntax.
      if (syntaxes.any((syntax) => syntax.tryMatch(this))) continue;

      // If we got here, it's just text.
      advanceBy(1);
    }

    // Unwind any unmatched tags and get the results.
    return _stack[0].close(this, null);
  }

  void writeText() {
    writeTextRange(start, pos);
    start = pos;
  }

  void writeTextRange(int start, int end) {
    if (end <= start) return;

    var text = source.substring(start, end);
    var nodes = _stack.last.children;

    // If the previous node is text too, just append.
    if (nodes.isNotEmpty && nodes.last is Text) {
      var textNode = nodes.last as Text;
      nodes[nodes.length - 1] = Text('${textNode.text}$text');
    } else {
      nodes.add(Text(text));
    }
  }

  /// Add [node] to the last [TagState] on the stack.
  void addNode(Node node) {
    _stack.last.children.add(node);
  }

  /// Push [state] onto the stack of [TagState]s.
  void openTag(TagState state) => _stack.add(state);

  void consume(int length) {
    pos += length;
    start = pos;
  }
}

/// Represents one kind of Markdown tag that can be parsed.
abstract class InlineSyntax {
  final RegExp pattern;

  /// The first character of [pattern], to be used as an efficient first check
  /// that this syntax matches the current parser position.
  final int? _startCharacter;

  /// Create a new [InlineSyntax] which matches text on [pattern].
  ///
  /// If [startCharacter] is passed, it is used as a pre-matching check which
  /// is faster than matching against [pattern].
  InlineSyntax(String pattern,
      {int? startCharacter, bool caseSensitive = true})
      : pattern =
            RegExp(pattern, multiLine: true, caseSensitive: caseSensitive),
        _startCharacter = startCharacter;

  /// Tries to match at the parser's current position.
  ///
  /// The parser's position can be overriden with [startMatchPos].
  /// Returns whether or not the pattern successfully matched.
  bool tryMatch(InlineParser parser, [int startMatchPos = 0]) {
    // startMatchPos ??= parser.pos; //
    startMatchPos = startMatchPos == 0 ? parser.pos : startMatchPos;

    // Before matching with the regular expression [pattern], which can be
    // expensive on some platforms, check if even the first character matches
    // this syntax.
    if (_startCharacter != null &&
        parser.source.codeUnitAt(startMatchPos) != _startCharacter) {
      return false;
    }

    final startMatch = matches(parser, startMatchPos);
    if (startMatch == null) return false;

    // Write any existing plain text up to this point.
    parser.writeText();

    if (onMatch(parser, startMatch)) parser.consume(startMatch[0]!.length);
    return true;
  }

  ///Test if this syntax matches the current source.
  Match? matches(InlineParser parser, int startMatchPos) =>
      pattern.matchAsPrefix(parser.source, startMatchPos);

  /// Processes [match], adding nodes to [parser] and possibly advancing
  /// [parser].
  ///
  /// Returns whether the caller should advance [parser] by `match[0].length`.
  bool onMatch(InlineParser parser, Match match);
}

/// Represents a hard line break.
class LineBreakSyntax extends InlineSyntax {
  LineBreakSyntax() : super(r'(?:\\|  +)\n');

  /// Create a void <br> element.
  @override
  bool onMatch(InlineParser parser, Match match) {
    parser.addNode(Element.empty('br'));
    return true;
  }
}

/// Matches stuff that should just be passed through as straight text.
class TextSyntax extends InlineSyntax {
  final String substitute;

  /// Create a new [TextSyntax] which matches text on [pattern].
  ///
  /// If [sub] is passed, it is used as a simple replacement for [pattern]. If
  /// [startCharacter] is passed, it is used as a pre-matching check which is
  /// faster than matching against [pattern].
  TextSyntax(String pattern, {String sub = '', int startCharacter = 0})
      : substitute = sub,
        super(pattern, startCharacter: startCharacter);

  /// Adds a [Text] node to [parser] and returns `true` if there is a
  /// [substitute], as long as the preceding character (if any) is not a `/`.
  ///
  /// Otherwise, the parser is advanced by the length of [match] and `false` is
  /// returned.
  @override
  bool onMatch(InlineParser parser, Match match) {
    if (substitute.isEmpty ||
        (match.start > 0 &&
            match.input.substring(match.start - 1, match.start) == '/')) {
      // Just use the original matched text.
      parser.advanceBy(match[0]!.length);
      return false;
    }

    // Insert the substitution.
    parser.addNode(Text(substitute));
    return true;
  }
}

/// Escape punctuation preceded by a backslash.
class EscapeSyntax extends InlineSyntax {
  EscapeSyntax() : super(r'''\\[!"#$%&'()*+,\-./:;<=>?@\[\\\]^_`{|}~]''');

  @override
  bool onMatch(InlineParser parser, Match match) {
    final char = match[0]!.codeUnitAt(1);
    // Insert the substitution. Why these three charactes are replaced with
    // their equivalent HTML entity referenced appears to be missing from the
    // CommonMark spec, but is very present in all of the examples.
    // https://talk.commonmark.org/t/entity-ification-of-quotes-and-brackets-missing-from-spec/3207
    if (char == $double_quote) {
      parser.addNode(Text('&quot;'));
    } else if (char == $lt) {
      parser.addNode(Text('&lt;'));
    } else if (char == $gt) {
      parser.addNode(Text('&gt;'));
    } else {
      parser.addNode(Text(match[0]![1]));
    }
    return true;
  }
}

/// Leave inline HTML tags alone, from
/// [CommonMark 0.28](http://spec.commonmark.org/0.28/#raw-html).
///
/// This is not actually a good definition (nor CommonMark's) of an HTML tag,
/// but it is fast. It will leave text like `<a href='hi">` alone, which is
/// incorrect.
///
/// TODO(srawlins): improve accuracy while ensuring performance, once
/// Markdown benchmarking is more mature.
class InlineHtmlSyntax extends TextSyntax {
  InlineHtmlSyntax()
      : super(r'<[/!?]?[A-Za-z][A-Za-z0-9-]*(?:\s[^>]*)?>',
            startCharacter: $lt);
}

/// Matches autolinks like `<foo@bar.example.com>`.
///
/// See <http://spec.commonmark.org/0.28/#email-address>.
class EmailAutolinkSyntax extends InlineSyntax {
  static final _email =
      r'''[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}'''
      r'''[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*''';

  EmailAutolinkSyntax() : super('<($_email)>', startCharacter: $lt);

  @override
  bool onMatch(InlineParser parser, Match match) {
    var url = match[1] ?? '';
    var text = parser.document.encodeHtml ? escapeHtml(url) : url;
    var anchor = Element.text('a', text);
    anchor.attributes['href'] = Uri.encodeFull('mailto:$url');
    parser.addNode(anchor);

    return true;
  }
}

/// Matches autolinks like `<http://foo.com>`.
class AutolinkSyntax extends InlineSyntax {
  AutolinkSyntax() : super(r'<(([a-zA-Z][a-zA-Z\-\+\.]+):(?://)?[^\s>]*)>');

  @override
  bool onMatch(InlineParser parser, Match match) {
    var url = match[1] ?? '';
    var text = parser.document.encodeHtml ? escapeHtml(url) : url;
    var anchor = Element.text('a', text);
    anchor.attributes['href'] = Uri.encodeFull(url);
    parser.addNode(anchor);

    return true;
  }
}

/// Matches autolinks like `http://foo.com`.
class AutolinkExtensionSyntax extends InlineSyntax {
  /// Broken up parts of the autolink regex for reusability and readability

  // Autolinks can only come at the beginning of a line, after whitespace, or
  // any of the delimiting characters *, _, ~, and (.
  static const start = r'(?:^|[\s*_~(>])';

  // An extended url autolink will be recognized when one of the schemes
  // http://, https://, or ftp://, followed by a valid domain
  static const scheme = r'(?:(?:https?|ftp):\/\/|www\.)';

  // A valid domain consists of alphanumeric characters, underscores (_),
  // hyphens (-) and periods (.). There must be at least one period, and no
  // underscores may be present in the last two segments of the domain.
  static const domainPart = r'\w\-';
  static const domain = '[$domainPart][$domainPart.]+';

  // A valid domain consists of alphanumeric characters, underscores (_),
  // hyphens (-) and periods (.).
  static const path = r'[^\s<]*';

  // Trailing punctuation (specifically, ?, !, ., ,, :, *, _, and ~) will not
  // be considered part of the autolink
  static const truncatingPunctuationPositive = r'[?!.,:*_~]';

  static final regExpTrailingPunc = RegExp('$truncatingPunctuationPositive*\$');
  static final regExpEndsWithColon = RegExp(r'\&[a-zA-Z0-9]+;$');
  static final regExpWhiteSpace = RegExp(r'\s');

  AutolinkExtensionSyntax() : super('$start(($scheme)($domain)($path))');

  @override
  bool tryMatch(InlineParser parser, [int startMatchPos=0]) {
    return super.tryMatch(parser, parser.pos > 0 ? parser.pos - 1 : 0);
  }

  @override
  bool onMatch(InlineParser parser, Match match) {
    var url = match.groupCount>0? match[1]??'':'';
    var href = url;
    var matchLength = url.length;

    if (url[0] == '>' || url.startsWith(regExpWhiteSpace)) {
      url = url.substring(1, url.length - 1);
      href = href.substring(1, href.length - 1);
      parser.pos++;
      matchLength--;
    }

    // Prevent accidental standard autolink matches
    if (url.endsWith('>') && parser.source[parser.pos - 1] == '<') {
      return false;
    }

    // When an autolink ends in ), we scan the entire autolink for the total
    // number of parentheses. If there is a greater number of closing
    // parentheses than opening ones, we don’t consider the last character
    // part of the autolink, in order to facilitate including an autolink
    // inside a parenthesis:
    // https://github.github.com/gfm/#example-600
    if (url.endsWith(')')) {
      final opening = _countChars(url, '(');
      final closing = _countChars(url, ')');

      if (closing > opening) {
        url = url.substring(0, url.length - 1);
        href = href.substring(0, href.length - 1);
        matchLength--;
      }
    }

    // Trailing punctuation (specifically, ?, !, ., ,, :, *, _, and ~) will
    // not be considered part of the autolink, though they may be included
    // in the interior of the link:
    // https://github.github.com/gfm/#example-599
    final trailingPunc = regExpTrailingPunc.firstMatch(url);
    if (trailingPunc != null) {
      url = url.substring(0, url.length - trailingPunc[0]!.length);
      href = href.substring(0, href.length - trailingPunc[0]!.length);
      matchLength -= trailingPunc[0]!.length;
    }

    // If an autolink ends in a semicolon (;), we check to see if it appears
    // to resemble an
    // [entity reference](https://github.github.com/gfm/#entity-references);
    // if the preceding text is & followed by one or more alphanumeric
    // characters. If so, it is excluded from the autolink:
    // https://github.github.com/gfm/#example-602
    if (url.endsWith(';')) {
      final entityRef = regExpEndsWithColon.firstMatch(url);
      if (entityRef != null) {
        // Strip out HTML entity reference
        url = url.substring(0, url.length - entityRef[0]!.length);
        href = href.substring(0, href.length - entityRef[0]!.length);
        matchLength -= entityRef[0]!.length;
      }
    }

    // The scheme http will be inserted automatically
    if (!href.startsWith('http://') &&
        !href.startsWith('https://') &&
        !href.startsWith('ftp://')) {
      href = 'http://$href';
    }

    final text = parser.document.encodeHtml ? escapeHtml(url) : url;
    final anchor = Element.text('a', text);
    anchor.attributes['href'] = Uri.encodeFull(href);
    parser.addNode(anchor);

    parser.consume(matchLength);
    return false;
  }

  int _countChars(String input, String char) {
    var count = 0;

    for (var i = 0; i < input.length; i++) {
      if (input[i] == char) count++;
    }

    return count;
  }
}

class DelimiterRun {
  /// According to
  /// [CommonMark](https://spec.commonmark.org/0.29/#punctuation-character):
  ///
  /// > A punctuation character is an ASCII punctuation character or anything in
  /// > the general Unicode categories `Pc`, `Pd`, `Pe`, `Pf`, `Pi`, `Po`, or
  /// > `Ps`.
  // This RegExp is inspired by
  // https://github.com/commonmark/commonmark.js/blob/1f7d09099c20d7861a674674a5a88733f55ff729/lib/inlines.js#L39.
  // I don't know if there is any way to simplify it or maintain it.
  static final RegExp punctuation = RegExp(r'['
      r'''!"#$%&'()*+,\-./:;<=>?@\[\]\\^_`{|}~'''
      r'\xA1\xA7\xAB\xB6\xB7\xBB\xBF\u037E\u0387\u055A-\u055F\u0589\u058A\u05BE'
      r'\u05C0\u05C3\u05C6\u05F3\u05F4\u0609\u060A\u060C\u060D\u061B\u061E'
      r'\u061F\u066A-\u066D\u06D4\u0700-\u070D\u07F7-\u07F9\u0830-\u083E\u085E'
      r'\u0964\u0965\u0970\u0AF0\u0DF4\u0E4F\u0E5A\u0E5B\u0F04-\u0F12\u0F14'
      r'\u0F3A-\u0F3D\u0F85\u0FD0-\u0FD4\u0FD9\u0FDA\u104A-\u104F\u10FB'
      r'\u1360-\u1368\u1400\u166D\u166E\u169B\u169C\u16EB-\u16ED\u1735\u1736'
      r'\u17D4-\u17D6\u17D8-\u17DA\u1800-\u180A\u1944\u1945\u1A1E\u1A1F'
      r'\u1AA0-\u1AA6\u1AA8-\u1AAD\u1B5A-\u1B60\u1BFC-\u1BFF\u1C3B-\u1C3F\u1C7E'
      r'\u1C7F\u1CC0-\u1CC7\u1CD3\u2010-\u2027\u2030-\u2043\u2045-\u2051'
      r'\u2053-\u205E\u207D\u207E\u208D\u208E\u2308-\u230B\u2329\u232A'
      r'\u2768-\u2775\u27C5\u27C6\u27E6-\u27EF\u2983-\u2998\u29D8-\u29DB\u29FC'
      r'\u29FD\u2CF9-\u2CFC\u2CFE\u2CFF\u2D70\u2E00-\u2E2E\u2E30-\u2E42'
      r'\u3001-\u3003\u3008-\u3011\u3014-\u301F\u3030\u303D\u30A0\u30FB\uA4FE'
      r'\uA4FF\uA60D-\uA60F\uA673\uA67E\uA6F2-\uA6F7\uA874-\uA877\uA8CE\uA8CF'
      r'\uA8F8-\uA8FA\uA8FC\uA92E\uA92F\uA95F\uA9C1-\uA9CD\uA9DE\uA9DF'
      r'\uAA5C-\uAA5F\uAADE\uAADF\uAAF0\uAAF1\uABEB\uFD3E\uFD3F\uFE10-\uFE19'
      r'\uFE30-\uFE52\uFE54-\uFE61\uFE63\uFE68\uFE6A\uFE6B\uFF01-\uFF03'
      r'\uFF05-\uFF0A\uFF0C-\uFF0F\uFF1A\uFF1B\uFF1F\uFF20\uFF3B-\uFF3D\uFF3F'
      r'\uFF5B\uFF5D\uFF5F-\uFF65'
      ']');

  // TODO(srawlins): Unicode whitespace
  static final String whitespace = ' \t\r\n';

  final int char;
  final int length;
  final bool isLeftFlanking;
  final bool isRightFlanking;
  final bool isPrecededByPunctuation;
  final bool isFollowedByPunctuation;

  DelimiterRun._({
   required this.char,
   required this.length,
   required this.isLeftFlanking,
   required this.isRightFlanking,
   required this.isPrecededByPunctuation,
   required this.isFollowedByPunctuation,
  });

  static DelimiterRun? tryParse(String source, int runStart, int runEnd) {
    bool leftFlanking,
        rightFlanking,
        precededByPunctuation,
        followedByPunctuation;
    String preceding, following;
    if (runStart == 0) {
      rightFlanking = false;
      preceding = '\n';
    } else {
      preceding = source.substring(runStart - 1, runStart);
    }
    precededByPunctuation = punctuation.hasMatch(preceding);

    if (runEnd == source.length - 1) {
      leftFlanking = false;
      following = '\n';
    } else {
      following = source.substring(runEnd + 1, runEnd + 2);
    }
    followedByPunctuation = punctuation.hasMatch(following);

    // http://spec.commonmark.org/0.28/#left-flanking-delimiter-run
    if (whitespace.contains(following)) {
      leftFlanking = false;
    } else {
      leftFlanking = !followedByPunctuation ||
          whitespace.contains(preceding) ||
          precededByPunctuation;
    }

    // http://spec.commonmark.org/0.28/#right-flanking-delimiter-run
    if (whitespace.contains(preceding)) {
      rightFlanking = false;
    } else {
      rightFlanking = !precededByPunctuation ||
          whitespace.contains(following) ||
          followedByPunctuation;
    }

    if (!leftFlanking && !rightFlanking) {
      // Could not parse a delimiter run.
      return null;
    }

    return DelimiterRun._(
      char: source.codeUnitAt(runStart),
      length: runEnd - runStart + 1,
      isLeftFlanking: leftFlanking,
      isRightFlanking: rightFlanking,
      isPrecededByPunctuation: precededByPunctuation,
      isFollowedByPunctuation: followedByPunctuation,
    );
  }

  @override
  String toString() =>
      '<char: $char, length: $length, isLeftFlanking: $isLeftFlanking, '
      'isRightFlanking: $isRightFlanking>';

  // Whether a delimiter in this run can open emphasis or strong emphasis.
  bool get canOpen =>
      isLeftFlanking &&
      (char == $asterisk || !isRightFlanking || isPrecededByPunctuation);

  // Whether a delimiter in this run can close emphasis or strong emphasis.
  bool get canClose =>
      isRightFlanking &&
      (char == $asterisk || !isLeftFlanking || isFollowedByPunctuation);
}

/// Matches syntax that has a pair of tags and becomes an element, like `*` for
/// `<em>`. Allows nested tags.
class TagSyntax extends InlineSyntax {
  final RegExp endPattern;

  /// Whether this is parsed according to the same nesting rules as [emphasis
  /// delimiters][].
  ///
  /// [emphasis delimiters]: http://spec.commonmark.org/0.28/#can-open-emphasis
  final bool requiresDelimiterRun;

  /// Create a new [TagSyntax] which matches text on [pattern].
  ///
  /// If [end] is passed, it is used as the pattern which denotes the end of
  /// matching text. Otherwise, [pattern] is used. If [requiresDelimiterRun] is
  /// passed, this syntax parses according to the same nesting rules as
  /// emphasis delimiters.  If [startCharacter] is passed, it is used as a
  /// pre-matching check which is faster than matching against [pattern].
  TagSyntax(String pattern,
      {String? end, this.requiresDelimiterRun = false, int? startCharacter})
      : endPattern = RegExp((end != null) ? end : pattern, multiLine: true),
        super(pattern, startCharacter: startCharacter);

  @override
  bool onMatch(InlineParser parser, Match match) {
    var runLength = match.group(0)!.length;
    var matchStart = parser.pos;
    var matchEnd = parser.pos + runLength - 1;
    if (!requiresDelimiterRun) {
      parser.openTag(TagState(parser.pos, matchEnd + 1, this, null));
      return true;
    }

    var delimiterRun =
        DelimiterRun.tryParse(parser.source, matchStart, matchEnd);
    if (delimiterRun != null && delimiterRun.canOpen) {
      parser.openTag(TagState(parser.pos, matchEnd + 1, this, delimiterRun));
      return true;
    } else {
      parser.advanceBy(runLength);
      return false;
    }
  }

  bool onMatchEnd(InlineParser parser, Match match, TagState state) {
    var runLength = match.group(0)!.length;
    var matchStart = parser.pos;
    var matchEnd = parser.pos + runLength - 1;
    var openingRunLength = state.endPos - state.startPos;
    var delimiterRun =
        DelimiterRun.tryParse(parser.source, matchStart, matchEnd);

    if (openingRunLength == 1 && runLength == 1) {
      parser.addNode(Element('em', state.children));
    } else if (openingRunLength == 1 && runLength > 1) {
      parser.addNode(Element('em', state.children));
      parser.pos = parser.pos - (runLength - 1);
      parser.start = parser.pos;
    } else if (openingRunLength > 1 && runLength == 1) {
      parser.openTag(
          TagState(state.startPos, state.endPos - 1, this, delimiterRun));
      parser.addNode(Element('em', state.children));
    } else if (openingRunLength == 2 && runLength == 2) {
      parser.addNode(Element('strong', state.children));
    } else if (openingRunLength == 2 && runLength > 2) {
      parser.addNode(Element('strong', state.children));
      parser.pos = parser.pos - (runLength - 2);
      parser.start = parser.pos;
    } else if (openingRunLength > 2 && runLength == 2) {
      parser.openTag(
          TagState(state.startPos, state.endPos - 2, this, delimiterRun));
      parser.addNode(Element('strong', state.children));
    } else if (openingRunLength > 2 && runLength > 2) {
      parser.openTag(
          TagState(state.startPos, state.endPos - 2, this, delimiterRun));
      parser.addNode(Element('strong', state.children));
      parser.pos = parser.pos - (runLength - 2);
      parser.start = parser.pos;
    }

    return true;
  }
}

/// Matches strikethrough syntax according to the GFM spec.
class StrikethroughSyntax extends TagSyntax {
  StrikethroughSyntax([String pattern = '~+'])
      : super(pattern, requiresDelimiterRun: true);

  @override
  bool onMatchEnd(InlineParser parser, Match match, TagState state) {
    var runLength = match.group(0)!.length;
    var matchStart = parser.pos;
    var matchEnd = parser.pos + runLength - 1;
    var delimiterRun =
        DelimiterRun.tryParse(parser.source, matchStart, matchEnd);
    if (delimiterRun==null||!delimiterRun.isRightFlanking) {
      return false;
    }

    parser.addNode(Element(tag, state.children));
    return true;
  }

  ///The generated tag
  String get tag => 'del';
}

/// Matches links like `[blah][label]` and `[blah](url)`.
class LinkSyntax extends TagSyntax {
  static final _entirelyWhitespacePattern = RegExp(r'^\s*$');

  final Resolver? linkResolver;
  final LinkMapper? linkMapper;

  LinkSyntax(
      {Resolver? linkResolver,
      this.linkMapper,
      String pattern = r'\[',
      int startCharacter = $lbracket})
      : linkResolver = (linkResolver ?? (String _, [String __='']) => Element.empty('')), //
        super(pattern, end: r'\]', startCharacter: startCharacter);

  String _map(InlineParser parser, String url) =>
      linkMapper == null ? url : linkMapper!(parser, url);

  // The pending [TagState]s, all together, are "active" or "inactive" based on
  // whether a link element has just been parsed.
  //
  // Links cannot be nested, so we must "deactivate" any pending ones. For
  // example, take the following text:
  //
  //     Text [link and [more](links)](links).
  //
  // Once we have parsed `Text [`, there is one (pending) link in the state
  // stack.  It is, by default, active. Once we parse the next possible link,
  // `[more](links)`, as a real link, we must deactive the pending links (just
  // the one, in this case).
  var _pendingStatesAreActive = true;

  @override
  bool onMatch(InlineParser parser, Match match) {
    var matched = super.onMatch(parser, match);
    if (!matched) return false;

    _pendingStatesAreActive = true;

    return true;
  }

  @override
  bool onMatchEnd(InlineParser parser, Match match, TagState state) {
    if (!_pendingStatesAreActive) return false;

    var text = parser.source.substring(state.endPos, parser.pos);
    // The current character is the `]` that closed the link text. Examine the
    // next character, to determine what type of link we might have (a '('
    // means a possible inline link; otherwise a possible reference link).
    if (parser.pos + 1 >= parser.source.length) {
      // In this case, the Markdown document may have ended with a shortcut
      // reference link.

      return _tryAddReferenceLink(parser, state, text);
    }
    // Peek at the next character; don't advance, so as to avoid later stepping
    // backward.
    var char = parser.charAt(parser.pos + 1);

    if (char == $lparen) {
      // Maybe an inline link, like `[text](destination)`.
      parser.advanceBy(1);
      var leftParenIndex = parser.pos;
      var inlineLink = _parseInlineLink(parser);
      if (inlineLink != null) {
        return _tryAddInlineLink(parser, state, inlineLink);
      }
      // Reset the parser position.
      parser.pos = leftParenIndex;

      // At this point, we've matched `[...](`, but that `(` did not pan out to
      // be an inline link. We must now check if `[...]` is simply a shortcut
      // reference link.
      parser.advanceBy(-1);
      return _tryAddReferenceLink(parser, state, text);
    }

    if (char == $lbracket) {
      parser.advanceBy(1);
      // At this point, we've matched `[...][`. Maybe a *full* reference link,
      // like `[foo][bar]` or a *collapsed* reference link, like `[foo][]`.
      if (parser.pos + 1 < parser.source.length &&
          parser.charAt(parser.pos + 1) == $rbracket) {
        // That opening `[` is not actually part of the link. Maybe a
        // *shortcut* reference link (followed by a `[`).
        parser.advanceBy(1);
        return _tryAddReferenceLink(parser, state, text);
      }
      var label = _parseReferenceLinkLabel(parser);
      if (label != null) return _tryAddReferenceLink(parser, state, label);
      return false;
    }

    // The link text (inside `[...]`) was not followed with a opening `(` nor
    // an opening `[`. Perhaps just a simple shortcut reference link (`[...]`).

    return _tryAddReferenceLink(parser, state, text);
  }

  /// Resolve a possible reference link.
  ///
  /// Uses [linkReferences], [linkResolver], and [createNode] to try to
  /// resolve [label] and [state] into a [Node]. If [label] is defined in
  /// [linkReferences] or can be resolved by [linkResolver], returns a [Node]
  /// that links to the resolved URL.
  ///
  /// Otherwise, returns `null`.
  ///
  /// [label] does not need to be normalized.
  Node? _resolveReferenceLink(
    InlineParser parser,
    String label,
    TagState state,
    Map<String, LinkReference> linkReferences,
  ) {
    var linkReference = linkReferences[normalizeLinkLabel(label)];
    if (linkReference != null) {
      return createNode(parser, state, _map(parser, linkReference.destination),
          linkReference.title);
    } else if(linkResolver!=null){
      // This link has no reference definition. But we allow users of the
      // library to specify a custom resolver function ([linkResolver]) that
      // may choose to handle this. Otherwise, it's just treated as plain
      // text.

      // Normally, label text does not get parsed as inline Markdown. However,
      // for the benefit of the link resolver, we need to at least escape
      // brackets, so that, e.g. a link resolver can receive `[\[\]]` as `[]`.
      return linkResolver!(label
          .replaceAll(r'\\', r'\')
          .replaceAll(r'\[', '[')
          .replaceAll(r'\]', ']'));
    }
    return null;
  }

  /// Create the node represented by a Markdown link.
  Node createNode(
      InlineParser parser, TagState state, String destination, String title) {
    var element = Element('a', state.children);
    element.attributes['href'] = escapeAttribute(destination);
    if (title != null && title.isNotEmpty) {
      element.attributes['title'] = escapeAttribute(title);
    }
    return element;
  }

  // Add a reference link node to [parser]'s AST.
  //
  // Returns whether the link was added successfully.
  bool _tryAddReferenceLink(InlineParser parser, TagState state, String label) {
    var element = _resolveReferenceLink(
        parser, label, state, parser.document.linkReferences);
    if (element == null) {
      return false;
    }
    parser.addNode(element);
    parser.start = parser.pos;
    _pendingStatesAreActive = false;
    return true;
  }

  // Add an inline link node to [parser]'s AST.
  //
  // Returns whether the link was added successfully.
  bool _tryAddInlineLink(InlineParser parser, TagState state, InlineLink link) {
    var element =
        createNode(parser, state, _map(parser, link.destination), link.title);
    if (element == null) return false;
    parser.addNode(element);
    parser.start = parser.pos;
    _pendingStatesAreActive = false;
    return true;
  }

  /// Parse a reference link label at the current position.
  ///
  /// Specifically, [parser.pos] is expected to be pointing at the `[` which
  /// opens the link label.
  ///
  /// Returns the label if it could be parsed, or `null` if not.
  String _parseReferenceLinkLabel(InlineParser parser) {
    // Walk past the opening `[`.
    parser.advanceBy(1);
    // if (parser.isDone) return null;
    if (parser.isDone) return '';

    var buffer = StringBuffer();
    while (true) {
      var char = parser.charAt(parser.pos);
      if (char == $backslash) {
        parser.advanceBy(1);
        var next = parser.charAt(parser.pos);
        if (next != $backslash && next != $rbracket) {
          buffer.writeCharCode(char);
        }
        buffer.writeCharCode(next);
      } else if (char == $rbracket) {
        break;
      } else {
        buffer.writeCharCode(char);
      }
      parser.advanceBy(1);
      // if (parser.isDone) return null;
      if (parser.isDone) return ''; //
      // TODO(srawlins): only check 999 characters, for performance reasons?
    }

    var label = buffer.toString();

    // A link label must contain at least one non-whitespace character.
    // if (_entirelyWhitespacePattern.hasMatch(label)) return null;
    if (_entirelyWhitespacePattern.hasMatch(label)) return ''; //

    return label;
  }

  /// Parse an inline [InlineLink] at the current position.
  ///
  /// At this point, we have parsed a link's (or image's) opening `[`, and then
  /// a matching closing `]`, and [parser.pos] is pointing at an opening `(`.
  /// This method will then attempt to parse a link destination wrapped in `<>`,
  /// such as `(<http://url>)`, or a bare link destination, such as
  /// `(http://url)`, or a link destination with a title, such as
  /// `(http://url "title")`.
  ///
  /// Returns the [InlineLink] if one was parsed, or `null` if not.
  static InlineLink? _parseInlineLink(_SimpleParser parser) {
    // Start walking to the character just after the opening `(`.
    parser.advanceBy(1);

    _moveThroughWhitespace(parser);
    if (parser.isDone) return null; // EOF. Not a link.

    if (parser.charAt(parser.pos) == $lt) {
      // Maybe a `<...>`-enclosed link destination.
      return _parseInlineBracketedLink(parser);
    } else {
      return _parseInlineBareDestinationLink(parser);
    }
  }

  /// Parse an inline link with a bracketed destination (a destination wrapped
  /// in `<...>`). The current position of the parser must be the first
  /// character of the destination.
  static InlineLink? _parseInlineBracketedLink(_SimpleParser parser) {
    parser.advanceBy(1);

    var buffer = StringBuffer();
    while (true) {
      var char = parser.charAt(parser.pos);
      if (char == $backslash) {
        parser.advanceBy(1);
        var next = parser.charAt(parser.pos);
        if (_whitespaces.contains(char)) {
          // Not a link (no whitespace allowed within `<...>`).
          return null;
        }
        // TODO: Follow the backslash spec better here.
        // http://spec.commonmark.org/0.28/#backslash-escapes
        if (next != $backslash && next != $gt) {
          buffer.writeCharCode(char);
        }
        buffer.writeCharCode(next);
      } else if (_whitespaces.contains(char)) {
        // Not a link (no whitespace allowed within `<...>`).
        return null;
      } else if (char == $gt) {
        break;
      } else {
        buffer.writeCharCode(char);
      }
      parser.advanceBy(1);
      if (parser.isDone) return null;
    }
    var destination = buffer.toString();

    parser.advanceBy(1);
    var char = parser.charAt(parser.pos);
    if (_whitespaces.contains(char)) {
      var title = _parseTitle(parser);
      if (title == null &&
          (parser.isDone || parser.charAt(parser.pos) != $rparen)) {
        // This looked like an inline link, until we found this $space
        // followed by mystery characters; no longer a link.
        return null;
      }
      return InlineLink(destination, title: title??'');
    } else if (char == $rparen) {
      return InlineLink(destination);
    } else {
      // We parsed something like `[foo](<url>X`. Not a link.
      return null;
    }
  }

  /// Parse an inline link with a "bare" destination (a destination _not_
  /// wrapped in `<...>`). The current position of the parser must be the first
  /// character of the destination.
  static InlineLink? _parseInlineBareDestinationLink(_SimpleParser parser) {
    // According to
    // [CommonMark](http://spec.commonmark.org/0.28/#link-destination):
    //
    // > A link destination consists of [...] a nonempty sequence of
    // > characters [...], and includes parentheses only if (a) they are
    // > backslash-escaped or (b) they are part of a balanced pair of
    // > unescaped parentheses.
    //
    // We need to count the open parens. We start with 1 for the paren that
    // opened the destination.
    var parenCount = 1;
    var buffer = StringBuffer();

    while (true) {
      var char = parser.charAt(parser.pos);
      switch (char) {
        case $backslash:
          parser.advanceBy(1);
          if (parser.isDone) return null; // EOF. Not a link.
          var next = parser.charAt(parser.pos);
          // Parentheses may be escaped.
          //
          // http://spec.commonmark.org/0.28/#example-467
          if (next != $backslash && next != $lparen && next != $rparen) {
            buffer.writeCharCode(char);
          }
          buffer.writeCharCode(next);
          break;

        case $lf:
        case $cr:
        case $ff:
          var destination = buffer.toString();
          var title = _parseTitle(parser);
          if (title == null &&
              (parser.isDone || parser.charAt(parser.pos) != $rparen)) {
            // This looked like an inline link, until we found this $space
            // followed by mystery characters; no longer a link.
            return null;
          }
          // [_parseTitle] made sure the title was follwed by a closing `)`
          // (but it's up to the code here to examine the balance of
          // parentheses).
          parenCount--;
          if (parenCount == 0) {
            return InlineLink(destination, title: title??'');
          }
          break;

        case $lparen:
          parenCount++;
          buffer.writeCharCode(char);
          break;

        case $rparen:
          parenCount--;
          if (parenCount == 0) {
            var destination = buffer.toString();
            return InlineLink(destination);
          }
          buffer.writeCharCode(char);
          break;

        default:
          buffer.writeCharCode(char);
      }
      parser.advanceBy(1);
      if (parser.isDone) return null; // EOF. Not a link.
    }
  }

  // Walk the parser forward through any whitespace.
  static void _moveThroughWhitespace(_SimpleParser parser) {
    while (!parser.isDone) {
      var char = parser.charAt(parser.pos);
      if (!_whitespaces.contains(char) && char != $tab && char != $vt) {
        return;
      }
      parser.advanceBy(1);
    }
  }

  // Parse a link title in [parser] at it's current position. The parser's
  // current position should be a whitespace character that followed a link
  // destination.
  static String? _parseTitle(_SimpleParser parser) {
    _moveThroughWhitespace(parser);
    if (parser.isDone) return null;

    // The whitespace should be followed by a title delimiter.
    var delimiter = parser.charAt(parser.pos);
    if (delimiter != $apostrophe &&
        delimiter != $quote &&
        delimiter != $lparen) {
      return null;
    }

    var closeDelimiter = delimiter == $lparen ? $rparen : delimiter;
    parser.advanceBy(1);

    // Now we look for an un-escaped closing delimiter.
    var buffer = StringBuffer();
    while (true) {
      var char = parser.charAt(parser.pos);
      if (char == $backslash) {
        parser.advanceBy(1);
        var next = parser.charAt(parser.pos);
        if (next != $backslash && next != closeDelimiter) {
          buffer.writeCharCode(char);
        }
        buffer.writeCharCode(next);
      } else if (char == closeDelimiter) {
        break;
      } else {
        buffer.writeCharCode(char);
      }
      parser.advanceBy(1);
      if (parser.isDone) return null;
    }
    var title = buffer.toString();

    // Advance past the closing delimiter.
    parser.advanceBy(1);
    if (parser.isDone) return null;
    _moveThroughWhitespace(parser);
    if (parser.isDone) return null;
    if (parser.charAt(parser.pos) != $rparen) return null;
    return title;
  }
}

/// Matches images like `![alternate text](url "optional title")` and
/// `![alternate text][label]`.
class ImageSyntax extends LinkSyntax {
  ImageSyntax({Resolver? linkResolver, LinkMapper? linkMapper})
      : super(
            linkResolver: linkResolver,
            linkMapper: linkMapper,
            pattern: r'!\[',
            startCharacter: $exclamation);

  @override
  Node createNode(
      InlineParser parser, TagState state, String destination, String title) {
    var element = Element.empty('img');
    element.attributes['src'] = destination;
    element.attributes['alt'] = state?.textContent ?? '';
    if (title != null && title.isNotEmpty) {
      element.attributes['title'] =
          escapeAttribute(title.replaceAll('&', '&amp;'));
    }
    return element;
  }

  // Add an image node to [parser]'s AST.
  //
  // If [label] is present, the potential image is treated as a reference image.
  // Otherwise, it is treated as an inline image.
  //
  // Returns whether the image was added successfully.
  @override
  bool _tryAddReferenceLink(InlineParser parser, TagState state, String label) {
    var element = _resolveReferenceLink(
        parser, label, state, parser.document.linkReferences);
    if (element == null) {
      return false;
    }
    parser.addNode(element);
    parser.start = parser.pos;
    return true;
  }
}

/// Matches backtick-enclosed inline code blocks.
class CodeSyntax extends InlineSyntax {
  // This pattern matches:
  //
  // * a string of backticks (not followed by any more), followed by
  // * a non-greedy string of anything, including newlines, ending with anything
  //   except a backtick, followed by
  // * a string of backticks the same length as the first, not followed by any
  //   more.
  //
  // This conforms to the delimiters of inline code, both in Markdown.pl, and
  // CommonMark.
  static final String _pattern = r'(`+(?!`))((?:.|\n)*?[^`])\1(?!`)';

  CodeSyntax() : super(_pattern);

  @override
  bool tryMatch(InlineParser parser, [int startMatchPos = 0]) {
    if (parser.pos > 0 && parser.charAt(parser.pos - 1) == $backquote) {
      // Not really a match! We can't just sneak past one backtick to try the
      // next character. An example of this situation would be:
      //
      //     before ``` and `` after.
      //             ^--parser.pos
      return false;
    }

    var match = pattern.matchAsPrefix(parser.source, parser.pos);
    if (match == null) {
      return false;
    }
    parser.writeText();
    if (onMatch(parser, match)) parser.consume(match[0]!.length);
    return true;
  }

  @override
  bool onMatch(InlineParser parser, Match match) {
    if (match.groupCount < 2) return false;

    var code = match[2]!.trim().replaceAll('\n', ' ');
    if (parser.document.encodeHtml) code = escapeHtml(code);
    parser.addNode(Element.text('code', code));

    return true;
  }
}

/// Matches GitHub Markdown emoji syntax like `:smile:`.
///
/// There is no formal specification of GitHub's support for this colon-based
/// emoji support, so this syntax is based on the results of Markdown-enabled
/// text fields at github.com.
class EmojiSyntax extends InlineSyntax {
  // Emoji "aliases" are mostly limited to lower-case letters, numbers, and
  // underscores, but GitHub also supports `:+1:` and `:-1:`.
  EmojiSyntax() : super(':([a-z0-9_+-]+):');

  @override
  bool onMatch(InlineParser parser, Match match) {
    var alias = match[1];
    var emoji = emojis[alias];
    if (emoji == null) {
      parser.advanceBy(1);
      return false;
    }
    parser.addNode(Text(emoji));

    return true;
  }
}

/// Keeps track of a currently open tag while it is being parsed.
///
/// The parser maintains a stack of these so it can handle nested tags.
class TagState {
  /// The point in the original source where this tag started.
  final int startPos;

  /// The point in the original source where open tag ended.
  final int endPos;

  /// The syntax that created this node.
  final TagSyntax? syntax;

  /// The children of this node. Will be `null` for text nodes.
  final List<Node> children;

  final DelimiterRun? openingDelimiterRun;

  TagState(this.startPos, this.endPos, this.syntax, this.openingDelimiterRun)
      : children = <Node>[];

  /// Attempts to close this tag by matching the current text against its end
  /// pattern.
  bool tryMatch(InlineParser parser) {
    if (syntax == null) return false;
    var endMatch = syntax!.endPattern.matchAsPrefix(parser.source, parser.pos);
    if (endMatch == null) {
      return false;
    }

    if (!syntax!.requiresDelimiterRun) {
      // Close the tag.
      close(parser, endMatch);
      return true;
    }

    // TODO: Move this logic into TagSyntax.
    var runLength = endMatch.group(0)?.length ?? 0;
    var openingRunLength = endPos - startPos;
    var closingMatchStart = parser.pos;
    var closingMatchEnd = parser.pos + runLength - 1;
    var closingDelimiterRun = DelimiterRun.tryParse(
        parser.source, closingMatchStart, closingMatchEnd);
    if (closingDelimiterRun != null && closingDelimiterRun.canClose) {
      // Emphasis rules #9 and #10:
      var oneRunOpensAndCloses = (openingDelimiterRun != null &&
              openingDelimiterRun!.canOpen &&
              openingDelimiterRun!.canClose) ||
          (closingDelimiterRun.canOpen && closingDelimiterRun.canClose);
      if (oneRunOpensAndCloses &&
          (openingRunLength + closingDelimiterRun.length) % 3 == 0) {
        return false;
      }
      // Close the tag.
      close(parser, endMatch);
      return true;
    } else {
      return false;
    }
  }

  /// Pops this tag off the stack, completes it, and adds it to the output.
  ///
  /// Will discard any unmatched tags that happen to be above it on the stack.
  /// If this is the last node in the stack, returns its children.
  List<Node> close(InlineParser parser, Match? endMatch) {
    // If there are unclosed tags on top of this one when it's closed, that
    // means they are mismatched. Mismatched tags are treated as plain text in
    // markdown. So for each tag above this one, we write its start tag as text
    // and then adds its children to this one's children.
    var index = parser._stack.indexOf(this);

    // Remove the unmatched children.
    var unmatchedTags = parser._stack.sublist(index + 1);
    parser._stack.removeRange(index + 1, parser._stack.length);

    // Flatten them out onto this tag.
    for (var unmatched in unmatchedTags) {
      // Write the start tag as text.
      parser.writeTextRange(unmatched.startPos, unmatched.endPos);

      // Bequeath its children unto this tag.
      children.addAll(unmatched.children);
    }

    // Pop this off the stack.
    parser.writeText();
    parser._stack.removeLast();

    // If the stack is empty now, this is the special "results" node.
    if (parser._stack.isEmpty) return children;
    var endMatchIndex = parser.pos;

    if (endMatch != null) {
      if (syntax != null && syntax!.onMatchEnd(parser, endMatch, this)) {
        parser.consume(endMatch[0]!.length);
      } else {
        // Didn't close correctly so revert to text.
        parser.writeTextRange(startPos, endPos);
        parser._stack.last.children.addAll(children);
        parser.pos = endMatchIndex;
        parser.advanceBy(endMatch[0]!.length);
      }
    }
    // We are still parsing, so add this to its parent's children.

    // return null;
    return <Node>[]; //
  }

  String get textContent =>
      children.map((Node child) => child.textContent).join('');
}

class InlineLink {
  final String destination;
  final String title;
  late int end; //not used here but app can utilize it (tomyeh)

  InlineLink(this.destination, {this.title = ''});
}
