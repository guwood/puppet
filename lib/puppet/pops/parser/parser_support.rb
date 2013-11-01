require 'puppet/parser/functions'
require 'puppet/parser/files'
require 'puppet/resource/type_collection'
require 'puppet/resource/type_collection_helper'
require 'puppet/resource/type'
require 'monitor'

# Supporting logic for the parser.
# This supporting logic has slightly different responsibilities compared to the original Puppet::Parser::Parser.
# It is only concerned with parsing.
#
class Puppet::Pops::Parser::Parser
  # Note that the name of the contained class and the file name (currently parser_support.rb)
  # needs to be different as the class is generated by Racc, and this file (parser_support.rb) is included as a mix in
  #

  # Simplify access to the Model factory
  # Note that the parser/parser support does not have direct knowledge about the Model.
  # All model construction/manipulation is made by the Factory.
  #
  Factory = Puppet::Pops::Model::Factory
  Model = Puppet::Pops::Model

  include Puppet::Resource::TypeCollectionHelper

  attr_accessor :lexer

  # Returns the token text of the given lexer token, or nil, if token is nil
  def token_text t
    return t if t.nil?
    t = t.current if t.respond_to?(:current)
    return t.value if t.is_a? Model::QualifiedName

    # else it is a lexer token
    t[:value]
  end

  # Produces the fully qualified name, with the full (current) namespace for a given name.
  #
  # This is needed because class bodies are lazily evaluated and an inner class' container(s) may not
  # have been evaluated before some external reference is made to the inner class; its must therefore know its complete name
  # before evaluation-time.
  #
  def classname(name)
    [@lexer.namespace, name].join("::").sub(/^::/, '')
  end

  # Reinitializes variables (i.e. creates a new lexer instance
  #
  def clear
    initvars
  end

  # Raises a Parse error.
  def error(message, options = {})
    except = Puppet::ParseError.new(message)
    except.line = options[:line] || @lexer.line
    except.file = options[:file] || @lexer.file
    except.pos = options[:pos]   || @lexer.pos

    raise except
  end

  # Parses a file expected to contain pp DSL logic.
  def parse_file(file)
    unless Puppet::FileSystem::File.exist?(file)
      unless file =~ /\.pp$/
        file = file + ".pp"
      end
    end
    @lexer.file = file
    _parse()
  end

  def initialize()
    # Since the parser is not responsible for importing (removed), and does not perform linking,
    # and there is no syntax that requires knowing if something referenced exists, it is safe
    # to assume that no environment is needed when parsing. (All that comes later).
    #
    initvars
  end

  # Initializes the parser support by creating a new instance of {Puppet::Pops::Parser::Lexer}
  # @return [void]
  #
  def initvars
    @lexer = Puppet::Pops::Parser::Lexer.new
  end

  # This is a callback from the generated grammar (when an error occurs while parsing)
  # TODO Picks up origin information from the lexer, probably needs this from the caller instead
  #   (for code strings, and when start line is not line 1 in a code string (or file), etc.)
  #
  def on_error(token,value,stack)
    if token == 0 # denotes end of file
      value = 'end of file'
    else
      value = "'#{value[:value]}'"
    end
    error = "Syntax error at #{value}"

    # The 'expected' is only of value at end of input, otherwise any parse error involving a
    # start of a pair will be reported as expecting the close of the pair - e.g. "$x.each |$x {", would
    # report that "seeing the '{', the '}' is expected. That would be wrong.
    # Real "expected" tokens are very difficult to compute (would require parsing of racc output data). Output of the stack
    # could help, but can require extensive backtracking and produce many options.
    #
    if token == 0 && brace = @lexer.expected
      error += "; expected '#{brace}'"
    end

    except = Puppet::ParseError.new(error)
    except.line = @lexer.line
    except.file = @lexer.file if @lexer.file
    except.pos  = @lexer.pos

    raise except
  end

  # Parses a String of pp DSL code.
  # @todo make it possible to pass a given origin
  #
  def parse_string(code)
    @lexer.string = code
    _parse()
  end

  # Mark the factory wrapped model object with location information
  # @todo the lexer produces :line for token, but no offset or length
  # @return [Puppet::Pops::Model::Factory] the given factory
  # @api private
  #
  def loc(factory, start_token, end_token = nil)
    factory.record_position(sourcepos(start_token), sourcepos(end_token))
  end

  # Associate documentation with the factory wrapped model object.
  # @return [Puppet::Pops::Model::Factory] the given factory
  # @api private
  def doc factory, doc_string
    factory.doc = doc_string
  end

  def sourcepos(o)
    if !o
      Puppet::Pops::Adapters::SourcePosAdapter.new
    elsif o.is_a? Puppet::Pops::Model::Factory
      # It is a built model element with loc set returns start at pos 0
      o.loc
    else
      loc = Puppet::Pops::Adapters::SourcePosAdapter.new
      # It must be a token
      loc.line = o[:line]
      loc.pos = o[:pos]
      loc.offset = o[:offset]
      loc.length = o[:length]
      loc
    end
  end

  def aryfy(o)
    o = [o] unless o.is_a?(Array)
    o
  end

  # Transforms an array of expressions containing literal name expressions to calls if followed by an
  # expression, or expression list
  #
  def transform_calls(expressions)
    Factory.transform_calls(expressions)
  end

  # Performs the parsing and returns the resulting model.
  # The lexer holds state, and this is setup with {#parse_string}, or {#parse_file}.
  #
  # TODO: Drop support for parsing a ruby file this way (should be done where it is decided
  #   which file to load/run (i.e. loaders), and initial file to run
  # TODO: deal with options containing origin (i.e. parsing a string from externally known location).
  # TODO: should return the model, not a Hostclass
  #
  # @api private
  #
  def _parse()
    begin
      @yydebug = false
      main = yyparse(@lexer,:scan)
      # #Commented out now because this hides problems in the racc grammar while developing
      # # TODO include this when test coverage is good enough.
      #      rescue Puppet::ParseError => except
      #        except.line ||= @lexer.line
      #        except.file ||= @lexer.file
      #        except.pos  ||= @lexer.pos
      #        raise except
      #      rescue => except
      #        raise Puppet::ParseError.new(except.message, @lexer.file, @lexer.line, @lexer.pos, except)
    end
    main.record_origin(@lexer.file) if main
    return main
  ensure
    @lexer.clear
  end

end
