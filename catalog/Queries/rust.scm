[(line_comment) (block_comment)] @comment
[(string_literal) (raw_string_literal) (char_literal)] @string
[(integer_literal) (float_literal)] @number
(function_item name: (identifier) @function)
(type_identifier) @type
["fn" "let" "const" "pub" "use" "mod" "impl" "struct" "enum" "trait" "return" "if" "else" "for" "while" "loop" "match" "async" "await" "move" "unsafe" "where" "in" "break" "continue"] @keyword
(boolean_literal) @constant.builtin
