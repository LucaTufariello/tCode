[(comment) (multiline_comment)] @comment
[(line_string_literal) (multi_line_string_literal) (raw_string_literal)] @string
(integer_literal) @number
(type_identifier) @type
(function_declaration name: (simple_identifier) @function)
["func" "let" "var" "class" "struct" "enum" "protocol" "extension" "import" "return" "if" "guard" "for" "while" "switch" "case" "break" "continue" "try" "async" "await" "public" "private" "internal" "static" "mutating"] @keyword
