(comment) @comment
[(string_literal) (char_literal) (system_lib_string)] @string
(number_literal) @number
(type_identifier) @type
(primitive_type) @type.builtin
(function_declarator declarator: (identifier) @function)
["return" "if" "else" "for" "while" "do" "switch" "case" "break" "continue" "struct" "enum" "typedef" "const" "sizeof"] @keyword
