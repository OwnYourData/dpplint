require "test_helper"

class JsonDuplicatesTest < ActiveSupport::TestCase
  test "no repeated names" do
    assert_empty JsonDuplicates.find('{"a": 1, "b": {"a": 2}, "c": [{"a": 1}, {"a": 2}]}')
  end

  test "a repeated name with its normalized path and count" do
    assert_equal [{ path: "$['b'][1]", name: "x", count: 3 }],
                 JsonDuplicates.find('{"a":1,"b":[{"x":1},{"x":1,"x":2,"x":3}]}')
  end

  test "names are compared after their escapes are resolved" do
    assert_equal [{ path: "$", name: "a", count: 2 }], JsonDuplicates.find('{"a": 1, "a": 2}')
  end

  test "paths escape quotes, backslashes and control characters" do
    found = JsonDuplicates.find(%({"it's\\\\\\n": {"k": 1, "k": 2}}))
    assert_equal "$['it\\'s\\\\\\n']", found.first[:path]
  end

  test "strings, numbers and literals are skipped, also with escaped quotes" do
    assert_empty JsonDuplicates.find(%([1, -2.5e3, true, false, null, "a\\"b", {"q": "}"}]))
  end

  test "a byte order mark is accepted" do
    assert_empty JsonDuplicates.find("﻿{\"a\": 1}")
  end

  test "text that is not one JSON value is refused" do
    ['{"a": 1,}', '{"a" 1}', "[1 2]", '{"a": 1} x', "nul", "\xFF".b].each do |text|
      assert_raises(JsonDuplicates::Invalid, text) { JsonDuplicates.find(text) }
    end
  end

  test "very deep nesting is refused" do
    assert_raises(JsonDuplicates::Invalid) { JsonDuplicates.find(("[" * 600) + ("]" * 600)) }
  end
end
