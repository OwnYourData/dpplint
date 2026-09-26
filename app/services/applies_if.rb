# Evaluates the applies_if conditions of a criterion on the passport JSON.
# Supported paths: "$.attribute" and "$.attribute[?search(@, '<regex>')]".
class AppliesIf
  SIMPLE = /\A\$\.([A-Za-z_][A-Za-z0-9_]*)\z/
  SEARCH = /\A\$\.([A-Za-z_][A-Za-z0-9_]*)\[\?search\(@,\s*'(.*)'\)\]\z/

  def self.holds?(conditions, passport)
    Array(conditions).all? { |c| new(c, passport).holds? }
  end

  def initialize(condition, passport)
    @c = condition
    @passport = passport
  end

  def holds?
    values = select
    return values.any? == @c["exists"] if @c.key?("exists")
    return values.any? { |v| v == @c["equals"] } if @c.key?("equals")
    return values.any? { |v| @c["in"].include?(v) } if @c.key?("in")
    return values.any? { |v| v.to_s.match?(Regexp.new(@c["matches"])) } if @c.key?("matches")

    values.any?
  end

  private

  def select
    path = @c["path"].to_s
    if (m = path.match(SIMPLE))
      @passport.key?(m[1]) ? [@passport[m[1]]] : []
    elsif (m = path.match(SEARCH))
      Array(@passport[m[1]]).select { |v| v.to_s.match?(Regexp.new(m[2])) }
    else
      raise ArgumentError, "unsupported applies_if path #{path}"
    end
  end
end
