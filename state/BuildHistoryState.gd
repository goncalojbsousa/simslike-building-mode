extends RefCounted

var history: Array[Dictionary] = []
var redo_stack: Array[Dictionary] = []
var max_history: int = 50
