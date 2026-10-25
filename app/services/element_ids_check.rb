# Runs a criterion with check.type element_ids: whether the elementIds of the
# passport are unique (EN 18223 4.1.2.3, Table 2; "Check types",
# element_ids, in CRITERIA-FORMAT.md of dpp-criteria).
#
# In the expanded full serialization (EN 18223 Annex A; an `elements` array
# at the top level) the data elements are the objects with an elementId in
# the `elements` arrays of the passport, of its DataElementCollections and
# MultiValuedDataElements, and in the `value` array of a MultiValuedDataElement
# whose items are such objects.
#
# unique: level - every elementId once per array of data elements (a
#   violation for each one repeated). In the compressed serialization the
#   elementIds are JSON member names, so no JSON object of the passport as
#   delivered (`source`, the bytes of the response or of the posted body) may
#   contain a name twice; without those bytes the criterion is skipped.
# unique: passport - every elementId at one place of the passport (a warning
#   for each one used at several places). The items of a MultiValuedDataElement
#   count as one place, because they repeat one structure. Only the expanded
#   full serialization.
class ElementIdsCheck
  Outcome = Struct.new(:skipped, :code, :messages, keyword_init: true)

  Element = Struct.new(:id, :place, keyword_init: true)

  MAX_LISTED = 10

  def initialize(check, passport, source: nil)
    @check = check
    @passport = passport
    @source = source
  end

  def outcome
    if full?
      @check["unique"] == "passport" ? Outcome.new(messages: passport_messages) : Outcome.new(messages: level_messages)
    elsif @check["unique"] == "passport"
      Outcome.new(skipped: "the passport is in the compressed serialization, where elementIds cannot be told apart from " \
                           "attribute names without the data dictionary", code: "not_evaluated")
    elsif @source.nil?
      Outcome.new(skipped: "the passport is in the compressed serialization and is not available as delivered, so " \
                           "repeated member names cannot be seen", code: "not_evaluated")
    else
      compressed_level_outcome
    end
  end

  # The full serialization has an `elements` array at the top level.
  def full? = @passport.is_a?(Hash) && @passport["elements"].is_a?(Array)

  private

  def level_messages
    levels = []
    walk(@passport["elements"], [], [], levels: levels)
    repeated = levels.flat_map do |parent, ids|
      ids.tally.select { |_, n| n > 1 }.map { |id, n| "#{id} #{n} times #{where(parent)}" }
    end
    return [] if repeated.empty?

    [{ severity: "violation", message: "elementId repeated within one level: #{listed(repeated)}" }]
  end

  def passport_messages
    elements = []
    walk(@passport["elements"], [], [], elements: elements)
    places = elements.group_by(&:id).transform_values { |list| list.map(&:place).uniq }
    shared = places.select { |_, list| list.size > 1 }
    return [] if shared.empty?

    texts = shared.map { |id, list| "#{id} at #{list.size} places (#{list.map { |p| p.join('/') }.join(', ')})" }
    [{ severity: "warning", message: "elementId used at more than one place of the passport: #{listed(texts)}" }]
  end

  # Walks one array of data elements. path: the elementIds above it; place:
  # the same with "*" for the items of a MultiValuedDataElement.
  def walk(array, path, place, levels: nil, elements: nil)
    items = array.select { |e| e.is_a?(Hash) && e["elementId"].is_a?(String) }
    levels&.push([path, items.map { |e| e["elementId"] }])
    items.each do |e|
      id = e["elementId"]
      elements&.push(Element.new(id: id, place: place + [id]))
      multi = e["objectType"] == "MultiValuedDataElement"
      children(e).each do |list|
        if multi
          walk_items(list, path + [id], place + [id], levels: levels, elements: elements)
        else
          walk(list, path + [id], place + [id], levels: levels, elements: elements)
        end
      end
    end
  end

  # The items of a MultiValuedDataElement: one level for the repeated-id check;
  # below them, every item counts as the same place ("*").
  def walk_items(array, path, place, levels:, elements:)
    items = array.select { |e| e.is_a?(Hash) && e["elementId"].is_a?(String) }
    levels&.push([path, items.map { |e| e["elementId"] }])
    items.each do |e|
      id = e["elementId"]
      elements&.push(Element.new(id: id, place: place + ["*"]))
      multi = e["objectType"] == "MultiValuedDataElement"
      children(e).each do |list|
        if multi
          walk_items(list, path + [id], place + ["*"], levels: levels, elements: elements)
        else
          walk(list, path + [id], place + ["*"], levels: levels, elements: elements)
        end
      end
    end
  end

  # Arrays of data elements below an element: `elements`, and `value` if it
  # holds objects with an elementId (MultiValuedDataElement items, Annex A).
  def children(element)
    %w[elements value].filter_map do |key|
      list = element[key]
      list if list.is_a?(Array) && list.any? { |i| i.is_a?(Hash) && i["elementId"].is_a?(String) }
    end
  end

  def compressed_level_outcome
    duplicates = JsonDuplicates.find(@source)
    return Outcome.new(messages: []) if duplicates.empty?

    texts = duplicates.map { |d| "#{d[:name]} #{d[:count]} times in the object at #{d[:path]}" }
    Outcome.new(messages: [{ severity: "violation", message: "member name repeated within one JSON object: #{listed(texts)}" }])
  rescue JsonDuplicates::Invalid => e
    Outcome.new(skipped: "the passport as delivered cannot be read: #{e.message}", code: "not_evaluated")
  end

  def where(parent) = parent.empty? ? "at the top level of the passport" : "in #{parent.join('/')}"

  def listed(texts)
    more = texts.size > MAX_LISTED ? " and #{texts.size - MAX_LISTED} more" : ""
    "#{texts.first(MAX_LISTED).join('; ')}#{more}"
  end
end
