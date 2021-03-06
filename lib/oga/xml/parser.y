##
# DOM parser for both XML and HTML.
#
# Note that this parser itself does not deal with special HTML void elements.
# It requires every tag to have a closing tag. As such you'll need to enable
# HTML parsing mode when parsing HTML. This can be done as following:
#
#     parser = Oga::XML::Parser.new(:html => true)
#
class Oga::XML::Parser

token T_STRING T_TEXT
token T_DOCTYPE_START T_DOCTYPE_END T_DOCTYPE_TYPE T_DOCTYPE_NAME
token T_CDATA_START T_CDATA_END
token T_COMMENT_START T_COMMENT_END
token T_ELEM_START T_ELEM_NAME T_ELEM_NS T_ELEM_END T_ATTR
token T_XML_DECL_START T_XML_DECL_END

options no_result_var

rule
  document
    : expressions { on_document(val[0]) }
    | /* none */  { on_document }
    ;

  expressions
    : expressions expression { val.compact }
    | expression             { val }
    | /* none */             { [] }
    ;

  expression
    : doctype
    | cdata
    | comment
    | element
    | text
    | xmldecl
    ;

  # Doctypes

  doctype
    # <!DOCTYPE html>
    : T_DOCTYPE_START T_DOCTYPE_NAME T_DOCTYPE_END
      {
        on_doctype(val[1])
      }

    # <!DOCTYPE html PUBLIC>
    | T_DOCTYPE_START T_DOCTYPE_NAME T_DOCTYPE_TYPE T_DOCTYPE_END
      {
        on_doctype(val[1], val[2])
      }

    # <!DOCTYPE html PUBLIC "foo">
    | T_DOCTYPE_START T_DOCTYPE_NAME T_DOCTYPE_TYPE T_STRING T_DOCTYPE_END
      {
        on_doctype(val[1], val[2], val[3])
      }

    # <!DOCTYPE html PUBLIC "foo" "bar">
    | T_DOCTYPE_START T_DOCTYPE_NAME T_DOCTYPE_TYPE T_STRING T_STRING T_DOCTYPE_END
      {
        on_doctype(val[1], val[2], val[3], val[4])
      }
    ;

  # CDATA tags

  cdata
    # <![CDATA[]]>
    : T_CDATA_START T_CDATA_END { on_cdata }

    # <![CDATA[foo]]>
    | T_CDATA_START T_TEXT T_CDATA_END { on_cdata(val[1]) }
    ;

  # Comments

  comment
    # <!---->
    : T_COMMENT_START T_COMMENT_END { on_comment }

    # <!-- foo -->
    | T_COMMENT_START T_TEXT T_COMMENT_END { on_comment(val[1]) }
    ;

  # Elements

  element_open
    # <p>
    : T_ELEM_START T_ELEM_NAME { [nil, val[1]] }

    # <foo:p>
    | T_ELEM_START T_ELEM_NS T_ELEM_NAME { [val[1], val[2]] }
    ;

  element_start
    : element_open attributes { on_element(val[0][0], val[0][1], val[1]) }

  element
    : element_start expressions T_ELEM_END
      {
        if val[0]
          on_element_children(val[0], val[1] ? val[1].flatten : [])
        end

        after_element(val[0])
      }
    ;

  # Attributes

  attributes
    : attributes_ { on_attributes(val[0]) }
    | /* none */  { {} }
    ;

  attributes_
    : attributes_ attribute { val.flatten }
    | attribute             { val }
    ;

  attribute
    # foo
    : T_ATTR { {val[0] => nil} }

    # foo="bar"
    | T_ATTR T_STRING { {val[0] => val[1]} }
    ;

  # XML declarations
  xmldecl
    : T_XML_DECL_START T_XML_DECL_END            { on_xml_decl }
    | T_XML_DECL_START attributes T_XML_DECL_END { on_xml_decl(val[1]) }

  # Plain text

  text
    : T_TEXT { on_text(val[0]) }
    ;
end

---- inner
  ##
  # @param [String] data The input to parse.
  #
  # @param [Hash] options
  # @see Oga::XML::Lexer#initialize
  #
  def initialize(data, options = {})
    @data  = data
    @lexer = Lexer.new(data, options)

    reset
  end

  ##
  # Resets the internal state of the parser.
  #
  def reset
    @line = 1

    @lexer.reset
  end

  ##
  # Yields the next token from the lexer.
  #
  # @yieldparam [Array]
  #
  def yield_next_token
    @lexer.advance do |(type, value, line)|
      @line = line if line

      yield [type, value]
    end

    yield [false, false]
  end

  ##
  # @param [Fixnum] type The type of token the error occured on.
  # @param [String] value The value of the token.
  # @param [Array] stack The current stack of parsed nodes.
  # @raise [Racc::ParseError]
  #
  def on_error(type, value, stack)
    name  = token_to_str(type)
    index = @line - 1
    lines = @data.lines.to_a
    code  = ''

    # Show up to 5 lines before and after the offending line (if they exist).
    (-5..5).each do |offset|
      line   = lines[index + offset]
      number = @line + offset

      if line and number > 0
        if offset == 0
          prefix = '=> '
        else
          prefix = '   '
        end

        line = line.strip

        if line.length > 80
          line = line[0..79] + ' (more)'
        end

        code << "#{prefix}#{number}: #{line}\n"
      end
    end

    raise Racc::ParseError, <<-EOF.strip
Unexpected #{name} with value #{value.inspect} on line #{@line}:

#{code}
    EOF
  end

  ##
  # Parses the input and returns the corresponding AST.
  #
  # @example
  #  parser = Oga::Parser.new('<foo>bar</foo>')
  #  ast    = parser.parse
  #
  # @return [Oga::AST::Node]
  #
  def parse
    ast = yyparse(self, :yield_next_token)

    reset

    return ast
  end

  ##
  # @param [Array] children
  # @return [Oga::XML::Document]
  #
  def on_document(children = [])
    if children.is_a?(Array)
      children = children.flatten
    else
      children = [children]
    end

    document = Document.new

    children.each do |child|
      if child.is_a?(Doctype)
        document.doctype = child

      elsif child.is_a?(XmlDeclaration)
        document.xml_declaration = child

      else
        document.children << child
      end
    end

    link_children(document)

    return document
  end

  ##
  # @param [String] name
  # @param [String] type
  # @param [String] public_id
  # @param [String] system_id
  #
  def on_doctype(name, type = nil, public_id = nil, system_id = nil)
    return Doctype.new(
      :name      => name,
      :type      => type,
      :public_id => public_id,
      :system_id => system_id
    )
  end

  ##
  # @param [String] text
  # @return [Oga::XML::Cdata]
  #
  def on_cdata(text = nil)
    return Cdata.new(:text => text)
  end

  ##
  # @param [String] text
  # @return [Oga::XML::Comment]
  #
  def on_comment(text = nil)
    return Comment.new(:text => text)
  end

  ##
  # @param [Hash] attributes
  # @return [Oga::XML::XmlDeclaration]
  #
  def on_xml_decl(attributes = {})
    return XmlDeclaration.new(attributes)
  end

  ##
  # @param [String] text
  # @return [Oga::XML::Text]
  #
  def on_text(text)
    return Text.new(:text => text)
  end

  ##
  # @param [String] namespace
  # @param [String] name
  # @param [Hash] attributes
  # @param [Array] children
  # @return [Oga::XML::Element]
  #
  def on_element(namespace, name, attributes = {}, children = [])
    element = Element.new(
      :namespace  => namespace,
      :name       => name,
      :attributes => attributes,
      :children   => children
    )

    return element
  end

  ##
  # @param [Oga::XML::Element] element
  # @param [Array] children
  # @return [Oga::XML::Element]
  #
  def on_element_children(element, children = [])
    element.children = children

    link_children(element)

    return element
  end

  ##
  # @param [Oga::XML::Element]
  # @return [Oga::XML::Element]
  #
  def after_element(element)
    return element
  end

  ##
  # @param [Array] pairs
  # @return [Hash]
  #
  def on_attributes(pairs)
    attrs = {}

    pairs.each do |pair|
      attrs = attrs.merge(pair)
    end

    return attrs
  end

  private

  ##
  # Links the child nodes together by setting attributes such as the
  # previous, next and parent node.
  #
  # @param [Oga::XML::Node] node
  #
  def link_children(node)
    amount = node.children.length

    node.children.each_with_index do |child, index|
      prev_index = index - 1
      next_index = index + 1

      if index > 0
        child.previous = node.children[prev_index]
      end

      if next_index <= amount
        child.next = node.children[next_index]
      end

      child.parent = node
    end
  end

# vim: set ft=racc:
