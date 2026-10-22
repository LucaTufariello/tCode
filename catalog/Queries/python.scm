(comment) @comment
(string) @string
[(integer) (float)] @number
(function_definition name: (identifier) @function)
(class_definition name: (identifier) @type)
["def" "class" "return" "if" "elif" "else" "for" "while" "in" "import" "from" "as" "with" "try" "except" "finally" "raise" "yield" "lambda" "pass" "break" "continue" "async" "await" "and" "or" "not"] @keyword
[(true) (false) (none)] @constant.builtin
