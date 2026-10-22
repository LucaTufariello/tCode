(comment) @comment
[(string_literal) (raw_string_literal) (char_literal) (system_lib_string)] @string
(number_literal) @number
(type_identifier) @type
(primitive_type) @type.builtin
(function_declarator declarator: (identifier) @function)
["return" "if" "else" "for" "while" "do" "switch" "case" "break" "continue" "struct" "enum" "class" "namespace" "using" "template" "typename" "const" "constexpr" "new" "delete" "public" "private" "protected" "virtual" "override" "throw" "try" "catch"] @keyword
[(true) (false) (null)] @constant.builtin
