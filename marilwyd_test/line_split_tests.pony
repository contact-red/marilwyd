use "pony_check"
use "pony_test"
use "../marilwyd"

class \nodoc\ iso _TestSplitNeverExceedsTheBudget is Property1[String]
  """
  The property the whole thing exists for: no piece is longer than an IRC
  line may carry.

  A property rather than examples because the interesting inputs are the
  ones nobody writes down — text exactly at the budget, a byte over it, a
  multibyte character straddling the cut — and a uniform random string
  lands on none of them.
  """
  fun name(): String => "split/no piece exceeds the budget"

  fun gen(): Generator[String] =>
    _SplittableText()

  fun property(sample: String, h: PropertyHelper) =>
    for piece in SplitForIrc(sample, 40).values() do
      h.assert_true(
        piece.size() <= 40,
        "a piece was " + piece.size().string() + " bytes: " + piece)
    end

class \nodoc\ iso _TestSplitLosesNothing is Property1[String]
  """
  Every byte that was not a separator comes out again, in order.

  The counterweight to the bound above: a splitter that answered with
  nothing at all would satisfy "no piece is too long" perfectly.
  """
  fun name(): String => "split/no text is lost"

  fun gen(): Generator[String] =>
    _SplittableText()

  fun property(sample: String, h: PropertyHelper) =>
    let joined = String(sample.size())
    for piece in SplitForIrc(sample, 40).values() do
      joined.append(piece)
    end

    // Separators are dropped by design: newlines become line breaks, and a
    // space at a word break is consumed by it. What remains must match.
    let wanted = String(sample.size())
    for c in sample.values() do
      if (c != '\n') and (c != '\r') and (c != ' ') then
        wanted.push(c)
      end
    end
    let got = String(joined.size())
    for c in joined.values() do
      if c != ' ' then
        got.push(c)
      end
    end

    h.assert_eq[String](wanted.clone(), got.clone())

class \nodoc\ iso _TestSplitNeverAnswersEmptyPieces is Property1[String]
  """
  An empty piece costs a line and a pacing slot to say nothing, and at a
  quarter of a second each that is a visible pause in a channel.
  """
  fun name(): String => "split/no piece is empty"

  fun gen(): Generator[String] =>
    _SplittableText()

  fun property(sample: String, h: PropertyHelper) =>
    for piece in SplitForIrc(sample, 40).values() do
      h.assert_true(piece.size() > 0, "an empty piece was produced")
    end

primitive \nodoc\ _SplittableText
  """
  Text worth splitting.

  Weighted rather than uniform, because uniform random strings are all
  alike and none of them is the case that breaks a splitter. The mix is
  four parts ordinary prose, and one part each of the shapes that bite: a
  line exactly at a budget, one a byte over, text that is all separators,
  text with no break at all, and multibyte characters that must not be cut
  in half.
  """
  fun apply(): Generator[String] =>
    Generators.frequency[String](
      [ as WeightedGenerator[String]:
        (4, Generators.ascii_printable(where min = 0, max = 120))
        (1, Generators.one_of[String](
          [ ""
            " "
            "\n"
            "\n\n\n"
            "   \n  \r\n "
            "a"
            "." ]))
        (1, Generators.one_of[String](
          [ // Exactly the test budget, one under, one over.
            "0123456789012345678901234567890123456789"
            "012345678901234567890123456789012345678"
            "01234567890123456789012345678901234567890" ]))
        (1, Generators.one_of[String](
          [ // No break anywhere, so only the blind cut applies.
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            "..........................................."
            ",,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,," ]))
        (1, Generators.one_of[String](
          [ // Multibyte, which a blind cut would break in half.
            "ééééééééééééééééééééééééééééééééééééééééééééé"
            "bore da, sut mae? Dw i'n dysgu Cymraeg ers blwyddyn."
            "🏴󠁧󠁢󠁷󠁬󠁳󠁿🏴󠁧󠁢󠁷󠁬󠁳󠁿🏴󠁧󠁢󠁷󠁬󠁳󠁿🏴󠁧󠁢󠁷󠁬󠁳󠁿🏴󠁧󠁢󠁷󠁬󠁳󠁿" ]))
      ])

class \nodoc\ iso _TestNewlinesBecomeLines is UnitTest
  """
  Whatever the length. A bare newline in text sent to IRC would end the
  command and let what follows be read as another.
  """
  fun name(): String => "split/a newline is always a line break"

  fun apply(h: TestHelper) =>
    let pieces = SplitForIrc("one\ntwo\r\nthree")
    h.assert_eq[USize](3, pieces.size())
    h.assert_eq[String]("one", try pieces(0)? else "" end)
    h.assert_eq[String]("two", try pieces(1)? else "" end)
    h.assert_eq[String]("three", try pieces(2)? else "" end)

class \nodoc\ iso _TestShortTextIsOneLine is UnitTest
  fun name(): String => "split/text within the budget is one line"

  fun apply(h: TestHelper) =>
    let pieces = SplitForIrc("bore da")
    h.assert_eq[USize](1, pieces.size())
    h.assert_eq[String]("bore da", try pieces(0)? else "" end)

class \nodoc\ iso _TestABreakPrefersASentence is UnitTest
  """
  A period or comma before a space, so a break lands where a reader would
  have paused rather than mid-clause.
  """
  fun name(): String => "split/a break prefers a sentence end"

  fun apply(h: TestHelper) =>
    // Twenty bytes, with a period at 12 and spaces after it.
    let pieces = SplitForIrc("aaaa bbbb cc. dd ee ff", 20)
    h.assert_eq[String]("aaaa bbbb cc.", try pieces(0)? else "" end)

class \nodoc\ iso _TestABreakFallsBackToASpace is UnitTest
  fun name(): String => "split/a break falls back to a space"

  fun apply(h: TestHelper) =>
    let pieces = SplitForIrc("aaaa bbbb cccc dddd eeee", 20)
    h.assert_eq[String]("aaaa bbbb cccc dddd", try pieces(0)? else "" end)

class \nodoc\ iso _TestABreakCutsWhenItMust is UnitTest
  """
  Text offering neither is cut at the budget — a long word, a URL, a hash.
  """
  fun name(): String => "split/a break cuts when there is nowhere to break"

  fun apply(h: TestHelper) =>
    let pieces = SplitForIrc("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 10)
    h.assert_eq[USize](3, pieces.size())
    for piece in pieces.values() do
      h.assert_eq[USize](10, piece.size())
    end

class \nodoc\ iso _TestABlindCutKeepsCharactersWhole is UnitTest
  """
  A cut that lands inside a multibyte character produces mojibake on the
  far side, which is worse than a shorter line.
  """
  fun name(): String => "split/a blind cut does not break a character"

  fun apply(h: TestHelper) =>
    // Each é is two bytes, so a budget of 5 lands mid-character.
    let pieces = SplitForIrc("ééééééééé", 5)
    for piece in pieces.values() do
      h.assert_eq[USize](
        0, piece.size() % 2, "a two-byte character was cut: " + piece)
    end
