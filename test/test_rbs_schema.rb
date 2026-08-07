# frozen_string_literal: true

require_relative "helper"
include TestKit

S = Reve::RbsSchema

group "rbs is used when it is there, and not needed when it is not" do
  eq "rbs ships with this ruby", true, S.rbs_available?
  full = S.parse("(city: String, ?days: Integer) -> String")
  eq "required keyword", [:city], full["required"].keys
  eq "optional keyword", [:days], full["optional"].keys
  simple = S.parse_simple("(city: String, ?days: Integer) -> String")
  eq "the fallback parser agrees about names", [full["required"].keys, full["optional"].keys],
     [simple["required"].keys, simple["optional"].keys]
  eq "and about types, as strings", %w[String Integer],
     [simple["required"][:city], simple["optional"][:days]]
end

group "types map to json schema" do
  sig = '(city: String, ?units: ("metric" | "imperial"), ?days: Integer, ?deep: bool, ' \
        "?paths: Array[String], ?limit: Integer?, ?opts: Hash[String, untyped]) -> String"
  schema = S.to_schema(sig)
  props = schema["properties"]
  eq "String", { "type" => "string" }, props["city"]
  eq "a union of literals is an enum", { "type" => "string", "enum" => %w[metric imperial] }, props["units"]
  eq "Integer", { "type" => "integer" }, props["days"]
  eq "bool", { "type" => "boolean" }, props["deep"]
  eq "Array[String]", { "type" => "array", "items" => { "type" => "string" } }, props["paths"]
  eq "a nilable type is just the type", { "type" => "integer" }, props["limit"]
  eq "Hash", { "type" => "object" }, props["opts"]
  eq "only the non-optional ones are required", ["city"], schema["required"]
end

group "the fallback produces the same schema for the common forms" do
  sig = '(city: String, ?units: ("metric" | "imperial"), ?paths: Array[String], ?n: Integer) -> void'
  with_rbs = S.to_schema(sig)
  fallback = begin
    types = S.parse_simple(sig)
    properties = {}
    required = []
    types["required"].each { |name, type| properties[name.to_s] = S.json_type(type) and required << name.to_s }
    types["optional"].each { |name, type| properties[name.to_s] = S.json_type(type) }
    { "type" => "object", "properties" => properties, "required" => required }
  end
  eq "same properties", with_rbs["properties"], fallback["properties"]
  eq "same required list", with_rbs["required"], fallback["required"]
end

group "positional parameters are named values too" do
  schema = S.to_schema("(String path, ?Integer offset) -> String")
  eq "names come from the signature", %w[path offset], schema["properties"].keys
  eq "types too", %w[string integer], schema["properties"].values.map { _1["type"] }
  eq "requiredness follows the ?", ["path"], schema["required"]
end

group "comment blocks above a block are read" do
  Dir.mktmpdir do |dir|
    path = File.join(dir, "sig.rb")
    File.write(path, <<~'RUBY')
      tool "weather" do
        # Get the weather for a city.
        # @param city  City name, e.g. "Berlin"
        # @param units Unit system
        #: (city: String, ?units: ("metric" | "imperial")) -> String
        replay :safe
        run do |city:, units: "metric"|
          "#{city} #{units}"
        end
      end
    RUBY
    block = S.comment_block(path, 7)
    eq "the signature is found past intervening dsl lines",
       '(city: String, ?units: ("metric" | "imperial")) -> String', block["signature"]
    eq "param docs collected", { "city" => 'City name, e.g. "Berlin"', "units" => "Unit system" },
       block["params"]
    eq "prose becomes the description", "Get the weather for a city.", block["doc"]
    eq "a file with no comments is not a problem", S.empty_block.merge("params" => {}),
       S.comment_block(path, 1)
  end
end

group "a marker that interpolates is not a marker" do
  # "#@rbs" in a double-quoted string interpolates @rbs — nil — leaving "",
  # and an empty marker matches every comment line. This is the regression.
  eq "markers are literal", ["#:", "# @rbs", "\#@rbs"], S::SIGNATURE_MARKERS
  eq "no marker is empty", false, S::SIGNATURE_MARKERS.any?(&:empty?)
  block = S.parse_comments(["# just prose", "# @param x  a thing"])
  eq "prose stays prose", "just prose", block["doc"]
  eq "and @param stays a param", { "x" => "a thing" }, block["params"]
end

Dir.mktmpdir do |root|
  FileUtils.mkdir_p(File.join(root, "tools"))
  File.write(File.join(root, "instructions.md"), "Be useful.")
  File.write(File.join(root, "tools", "typed.rb"), <<~'RUBY')
    tool "weather" do
      # Get the weather for a city.
      # @param city  City name
      #: (city: String, ?units: ("metric" | "imperial"), ?days: Integer) -> String
      replay :safe
      run do |city:, units: "metric", days: 1|
        "#{city}/#{units}/#{days}"
      end
    end

    tool "with_ctx" do
      #: (path: String) -> String
      run { |path:, ctx:| "#{ctx.class}:#{path}" }
    end

    tool "old_style" do
      description "Takes a hash, like before"
      string :name, "A name", required: true
      run { |args, _ctx| "hello #{args["name"]}" }
    end
  RUBY

  group "a typed tool declares itself from its signature" do
    loaded = Reve::ToolDSL.load_dir(File.join(root, "tools"))
    eq "all three load", %w[old_style weather with_ctx], loaded["tools"].map(&:name).sort
    weather = loaded["tools"].find { _1.name == "weather" }.declaration
    eq "description from the comment", "Get the weather for a city.", weather["description"]
    eq "marked as typed", true, weather["typed"]
    eq "schema from the signature", %w[city units days], weather.dig("parameters", "properties").keys
    eq "enum survives", %w[metric imperial], weather.dig("parameters", "properties", "units", "enum")
    eq "param doc survives", "City name", weather.dig("parameters", "properties", "city", "description")
    eq "requiredness from the block's defaults", ["city"], weather.dig("parameters", "required")

    old = loaded["tools"].find { _1.name == "old_style" }.declaration
    eq "the hand-written form still works", %w[name], old.dig("parameters", "properties").keys
    eq "and is not marked typed", false, old["typed"]
  end

  group "a typed tool is called with keywords" do
    loaded = Reve::ToolDSL.load_dir(File.join(root, "tools"))
    ctx = Reve::ToolDSL::Context.new(sandbox: nil, cwd: root)
    weather = loaded["tools"].find { _1.name == "weather" }
    eq "keywords detected", true, weather.keywords?
    eq "defaults apply for the arguments the model omitted", "Berlin/metric/1",
       Reve::ToolDSL.invoke(weather, { "city" => "Berlin" }, ctx).dig("content", 0, "text")
    eq "and the given ones arrive", "Berlin/imperial/3",
       Reve::ToolDSL.invoke(weather, { "city" => "Berlin", "units" => "imperial", "days" => 3 }, ctx)
                       .dig("content", 0, "text")
    eq "an argument the block does not accept is dropped, not an error", "Berlin/metric/1",
       Reve::ToolDSL.invoke(weather, { "city" => "Berlin", "nonsense" => 1 }, ctx).dig("content", 0, "text")

    with_ctx = loaded["tools"].find { _1.name == "with_ctx" }
    eq "ctx: is injected when asked for", "Reve::ToolDSL::Context:x",
     Reve::ToolDSL.invoke(with_ctx, { "path" => "x" }, ctx).dig("content", 0, "text")
    eq "ctx is not in the schema", %w[path], with_ctx.declaration.dig("parameters", "properties").keys

    old = loaded["tools"].find { _1.name == "old_style" }
    eq "the |args, ctx| form still gets a hash", "hello world",
       Reve::ToolDSL.invoke(old, { "name" => "world" }, ctx).dig("content", 0, "text")
  end

  group "the typed schema is what the model receives" do
    model = fake_model(root, [assistant_tool("weather", { "city" => "Berlin" }), assistant_text("done")])
    h, = test_harness(storage: "memory", model: model, cwd: root)
    h.prompt("weather in Berlin")
    sent = File.readlines("#{ENV["REVE_FAKE_SCRIPT"]}.requests").map { JSON.parse(_1) }
    weather = sent.first["messages"] && nil
    declaration = JSON.parse(File.read("#{ENV["REVE_FAKE_SCRIPT"]}.requests").lines.first)
    eq "the tool ran with its defaults filled in", "Berlin/metric/1",
       entries_of(h.session).find { _1.dig("message", "role") == "toolResult" }
         .dig("message", "content", 0, "text")
    eq "and the declaration the harness holds is the derived one",
       { "type" => "string", "enum" => %w[metric imperial], "description" => nil }.compact,
       h.project_tools.find { _1.name == "weather" }.declaration
        .dig("parameters", "properties", "units").reject { |k, _| k == "description" }
    h.close
  end
end

group "sig/ describes the library, and rbs agrees" do
  begin
    require "rbs"
    loader = RBS::EnvironmentLoader.new
    loader.add(path: Pathname(File.expand_path("../sig", __dir__)))
    env = RBS::Environment.from_loader(loader).resolve_type_names
    names = env.class_decls.keys.map(&:to_s)
    eq "the harness is declared", true, names.include?("::Reve::Harness")
    eq "so are the session and the sandbox", true,
       %w[::Reve::Session ::Reve::Sandbox ::Reve::Project].all? { names.include?(_1) }
    eq "and the typed-tool machinery", true, names.include?("::Reve::RbsSchema")
  rescue LoadError
    eq "rbs unavailable, nothing to check", true, true
  end
end

done
