/*
    Copyright (c) 2014 Bastien Clément

    Permission is hereby granted, free of charge, to any person obtaining a
    copy of this software and associated documentation files (the
    "Software"), to deal in the Software without restriction, including
    without limitation the rights to use, copy, modify, merge, publish,
    distribute, sublicense, and/or sell copies of the Software, and to
    permit persons to whom the Software is furnished to do so, subject to
    the following conditions:

    The above copyright notice and this permission notice shall be included
    in all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
    OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
    MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
    IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
    CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
    TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
    SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
*/

%{

function error(str, loc) {
	if(loc)
		throw new Error("Parse error on line " + loc.first_line + ": " + str);
	else
		throw new Error("Parse error: " + str);
}

//
// Label
//
var label_counter = 466560;

function generateLabel() {
	return (label_counter++).toString(36);
}

//
// Type stuff
//
function normalizeType(type) {
	var aliases = {
		"bool":  "bit",
		"short": "byte",
		"dint":  "long"
	};
	
	return aliases[type] || type;
}

function typeWidth(type) {
	switch(type) {
		case "bit":
			return 0;
			
		case "byte":
			return 1;
		
		case "word":
		case "int":
			return 2;
			
		case "dword":
		case "longlong":
		case "real": return 4;
		
		default:
			throw new Error("Unknown type: " + type);
	}
}

function typeToLIST(type) {
	switch(type) {
		case "bit":
			return "BOOL";
			
		case "long":
			return "DINT";
		
		case "void":
		case "byte":
		case "word":
		case "int":
		case "dword":
		case "real":
			return type.toUpperCase();
		
		default:
			throw new Error("Unable to convert type to LIST: " + type);
	}
}

function castValue(value, type) {
	function err() {
		throw new Error("Cannot convert type '" + value.type + "' to '" + type + "'");
	}
	
	var typeCast = {
		"bit":   "boolean",
		"byte":  "integer",
		"word":  "integer",
		"int":   "integer",
		"dword": "integer",
		"long":  "integer",
		"real":  "real",
	};
	
	value.c_type = type;
	type = typeCast[type] || err();
	
	if(value.type === type) {
		return value;
	}

	return {
		$: "value",
		type: type,
		value: (function(val) {
			switch(type) {
				case "boolean":
					switch(value.type) {
						case "real":
						case "integer": return val ? true : false;
						default: err();
					}
				
				case "integer":
					switch(value.type) {
						case "boolean": return val ? 1 : 0;
						case "real":    return Math.floor(val);
						default: err();
					}
				
				case "real":
					switch(value.type) {
						case "boolean": return val ? 1 : 0;
						case "integer": return val;
						default: err();
					}
					
				default: err();
			}
		})(value.value)
	};
}

function compileValue(value, type) {
	function err() {
		throw new Error("Cannot compile '" + JSON.stringify(value) + "' to '" + type + "'");
	}
	
	switch(value.$) {
		case "value":
			val = castValue(value, type).value;
			return compileRawValue(val, type);
			break;
			
		default:
			throw new Error("Invalid value type: " + value.$);
	}
}

function compileRawValue(value, type) {
	function err() {
		throw new Error("Cannot compile '" + value + "' to '" + type + "'");
	}
	
	switch(type) {
		case "bit":  return value ? "TRUE" : "FALSE";
		case "byte": return "B#16#" + value.toString(16).toUpperCase();
		case "word": return "W#16#" + value.toString(16).toUpperCase();
		case "int":  return value.toString();
		case "dword": return "DW#16#" + value.toString(16).toUpperCase();
		case "long":  return "L#" + value.toString();
		case "real":  return value.toExponential();
		default: err();
	}
}

function dynCast(expr, type, _) {
	if(expr.$ === "value")
		return castValue(expr, type);
	
	if(expr.type === type) {
		return expr;
	} else if(expr.$ === "cast" || expr.type === "polymorphic") {
		expr.type = type;
		return expr;
	} else {
		return { $: "cast", type: type, expr: expr };
	}
}

function resolveType(sym, _) {
	if(sym.type) {
		return sym.type;
	}
	
	if(func_buf.scope[sym]) {
		return func_buf.scope[sym].type;
	}
	
	return getSymbol(sym, _).type;
}

//
// Memory management
//
var memorymap = [];

function registerMemoryBytes(byte, width) {
	for(var i = width; i > 0; i--, byte++) {
        if(memorymap[byte])
            error("Memory overlay detected at offset " + byte);
		memorymap[byte] = 0xFF;
	}
}

function registerMemoryBit(byte, offset) {
	memorymap[byte] = (memorymap[byte] | 0) | (1 << offset);
}

function allocMemory(width) {
	var offset = -1;
	
	for(var i = memorymap.length - 1; i >= 0; --i) {
		var free = true;
		
		for(var j = i; j-i < width; ++j) {
			if(memorymap[j]) {
				free = false;
				break;
			}
		}
		
		if(free) {
			offset = i;
			break;
		}
	}
	
	if(offset < 0)
		offset = memorymap.length;
		
	for(var i = 0; i < width; ++i)
		memorymap[offset + i] = 255;
	
	return offset;
}

var alloc_bit_byte = null;
var alloc_bit_offset = 0;

function allocBit() {
	if(alloc_bit_byte === null || alloc_bit_offset > 7) {
		alloc_bit_byte = allocMemory(1);
		alloc_bit_offset = 0;
	}
	
	return alloc_bit_byte + "." + (alloc_bit_offset++);
}

var array_ptr_addr = "MD " + allocMemory(4);
var array_buf_addr = "MD " + allocMemory(4);

function arrayDereference(push, ref, wrap, _) {
	var def = fnScopeResolve(ref.ref);
	
	if(wrap)
		push("T " + array_buf_addr);
	
	if(ref.index.type == "integer") {
		var idx = ref.index.value;
		if(idx == 0) {
			push("L P#" + def.offset + ".0");
		} else {
			var base_offset = parseInt(def.offset);
			if(def.twidth > 0) {
				push("L P#" + (base_offset + (idx * def.twidth)) + ".0");
			} else {
				var offset = Math.floor(idx / 8);
				var sub_offset = idx % 8;
				push("L P#" + (base_offset + offset) + "." + sub_offset);
			}
		}
	} else {
		push(compileExpr(dynCast(ref.index, "word", _), _));
		if(def.twidth > 0) {
			switch(def.twidth) {
				case 2:
					push("SLW 4");
					break;
					
				default:
					push("L " + def.twidth);
					push("*I");
			
				case 1:
					push("SLW 3");
					break;
			}
		}
		push("L P#" + def.offset + ".0");
		push("+D")
	}
	
	push("T " + array_ptr_addr);
	
	if(wrap)
		push("L " + array_buf_addr);
	
	var address_class;
	switch(ref.type) {
		case "bit":
			address_class = "M";
			break;
		
		case "byte":
			address_class = "MB";
			break;
			
		case "word":
		case "int":
			address_class = "MW";
			break;
			
		case "dword":
		case "long":
		case "real":
			address_class = "MD";
			break;
	}
	
	return address_class + " [" + array_ptr_addr + "]";
}

//
// Symbols
//
var symbols = {};
var force_symbol = false;

function registerSymbol(name, sym, _) {
	if(name[0] == "$" && !force_symbol)
		error("reserved symbol '" + name + "'", _);
	if(symbols[name])
		error("duplicate symbol '" + name + "'", _);
	symbols[name] = sym;
}

function getSymbol(name, _) {
	if(!symbols[name])
		error("undefined symbol '" + name + "'", _);
	return symbols[name];
}

//
// Externals
//
function dissectBinding(binding) {
	binding    = binding.replace(/^\@\s*/, "");
	var type   = binding[0];
	var width  = binding[1];
	var addr   = binding.slice(2);
	var suffix = width;
	
	switch(width) {
		case "B": width = 1; break;
		case "W": width = 2; break;
		case "D": width = 4; break;
		default:
			suffix = "";
			addr = width + addr;
			width = 0;
	}
	
	return {
		type:     type,
		fulltype: type + suffix,
		width:    width,
		addr:     addr
	};
}

function registerExternal(type, name, binding, _) {
	binding = dissectBinding(binding);
	if(binding.width != typeWidth(type))
		error("binding type width mismatch", _);
		
	if(binding.type === "M") {
		if(binding.width) {
			registerMemoryBytes(Number(binding.addr), binding.width);
		} else {
			var addr = binding.addr.split(".");
			registerMemoryBit(Number(addr[0]), Number(addr[1]));
		}
	}
	
	registerSymbol(name, {
		$:       "external",
		type:    type,
		addr:    binding.fulltype + " " + binding.addr,
		binding: binding
	}, _);
}

function registerExternalArray(type, name, length, binding, _) {
	binding = dissectBinding(binding);
	
	if(binding.type != "M") {
		error("Arrays must be bound to memory addresses", _);
	}
	
	if(length < 0) {
		error("Zero-sized array are not allowed", _);
	}
	
	var twidth = typeWidth(type);
	var alloc_length = twidth ? twidth * length : Math.floor((length - 1) / 8) + 1;
	registerMemoryBytes(parseInt(binding.addr), alloc_length);
	
	if(!twidth && binding.addr.split(".")[1] !== "0") {
		error("External bit arrays must be byte-aligned", _);
	}
	
	registerSymbol(name, {
		$:       "external-array",
		type:    type,
		length:  length,
		twidth:  twidth,
		offset:  binding.addr.split(".")[0]
	}, _);
}

//
// DB
//
var dbs = [];

function Datablock() {
	this.id = dbs.push(this);
	this.memory = [];
	this.map = {};
	this.entries = null;
}

Datablock.prototype.compile = function() {
	var entries = this.entries = [];
	this.memory.forEach(function(block) {
		switch(block.$) {
			case "unit":
				entries.push(block.entry);
				break;
			
			case "bits":
				block.bits.forEach(function(bit) {
					entries.push(bit);
				});
				break;
			
			case "padding":
				break;
			
			default:
				throw new Error("Unknown block type: " + block.$);
		}
	});
};

Datablock.prototype.register = function(name, type, def, _) {
	var entry = {
		name:        name,
		type:        type,
		width:       typeWidth(type),
		def:         def || { $: "value", type: "integer", value: 0 },
		offset:      0,
		bit_offset:  0,
	};
	
	if(this.map[name])
		error("Duplicate datablock entry name: " + name, _);
	this.map[name] = entry;
	
	(function(self) {
		switch(entry.width) {
			case 0:
				for(var i = self.memory.length - 1; i >= 0; --i) {
					var block = self.memory[i];
					if(block && block.$ == "bits" && block.bits.length < 8) {
						entry.offset = i;
						entry.bit_offset = block.bits.push(entry) - 1;
						return;
					}
				}
				
				var unit = { $: "bits", bits: [entry] };
				// no break
			
			case 1:
				if(entry.width == 1)
					var unit = { $: "unit", entry: entry };
				
				for(var i = self.memory.length - 1; i >= 0; --i) {
					if(!self.memory[i]) {
						entry.offset = i;
						self.memory[i] = unit;
						return;
					}
				}
				
				entry.offset = self.memory.push(unit) - 1;
				return;
			
			default:
				entry.offset = self.memory.length + (self.memory.length % 2);
				self.memory[entry.offset] = { $: "unit", entry: entry };
				for(var i = entry.offset + 1; i < (entry.offset + entry.width); ++i) {
					self.memory[i] = { $: "padding" };
				}
		}
	})(this);
	
	switch(entry.width) {
		case 0:
			entry.addr = "DB" + this.id + ".DBX " + entry.offset + "." + entry.bit_offset;
			break;
		
		case 1:
			entry.addr = "DB" + this.id + ".DBB " + entry.offset;
			break;
		
		case 2:
			entry.addr = "DB" + this.id + ".DBW " + entry.offset;
			break;
		
		case 4:
			entry.addr = "DB" + this.id + ".DBD " + entry.offset;
			break;
		
		default:
			throw new Error("Cannot address a " + entry.width + "-bytes object");
	}
	
	return entry;
};

Datablock.prototype.get = function(name, _) {
	if(this.map[name])
		return this.map[name];
	error("Unknown datablock entry: " + name, _);
};

Datablock.prototype.generate = function() {
	if(!this.entries)
		this.compile();
	
	var buffer = [];
	buffer.push("DATA_BLOCK DB " + this.id + "\n");
	buffer.push("  STRUCT\n");
	this.entries.forEach(function(entry, i) {
		buffer.push("   _" + i.toString(36).toUpperCase() + " : " + typeToLIST(entry.type));
		buffer.push(" ;\t// (" + entry.addr + ", " + entry.name + ")\n");
	});
	buffer.push("  END_STRUCT\n");
	buffer.push("BEGIN\n");
	this.entries.forEach(function(entry, i) {
		buffer.push("   _" + i.toString(36).toUpperCase() + " := " + compileValue(entry.def, entry.type) + " ;\n");
	});
	buffer.push("END_DATA_BLOCK\n\n");
	console.log(buffer.join(""));
}

function generateDbs() {
	dbs.forEach(function(db) { db.generate(); });
}

//
// Variables
//
var globals_db;

function registerGlobal(type, name, def, _) {
	if(!globals_db)
		globals_db = new Datablock;
	
	var entry = globals_db.register(name, type, def, _);
	
	registerSymbol(name, {
		$: "variable",
		type: type,
		addr: entry.addr,
		entry: entry
	}, _);
}

function getGlobal(name, _) {
	if(!globals_db)
		error("Globals datablock not defined.", _);
	return globals_db.get(name);
}

//
// Functions
//
var funcs = {};
var funcs_list = [];
var main_func = null;

var func_buf = null;

function fnScopeAdd(name, obj, _) {
	if(name[0] == "$")
		error("reserved symbol '" + name + "'", _);
		
	if(func_buf.scope[name]) {
		error("duplicate local symbol '" + name + "'", _);
	}
	
	if(!obj.addr)
		obj.addr = "#_" + Number(func_buf.scope_ctn++).toString(36);
	
	func_buf.scope[name] = obj;
}

function fnScopeResolve(name, _) {
	if(name === "RET_VAL")
		return {
			addr: "#" + name
		};
	
	if(func_buf.scope[name])
		return func_buf.scope[name];
	
	return getSymbol(name, _);
}

function fnBegin(definition, _) {
	func_buf = {
		type: definition.type,
		name: definition.name,
		id: "FC " + (funcs_list.length + 1),
		args: definition.args,
		body: "",
		scope_ctn: 0,
		scope: {},
		labels: {}
	};
	
	if(definition.name !== "MAIN") {
		registerSymbol(definition.name, {
			$: "function",
			type: definition.type,
			id: func_buf.id,
			entry: func_buf
		}, _);
	}
	
	definition.args.forEach(function(arg) {
		fnScopeAdd(arg.name, {
			$: "argument",
			type: arg.type,
			name: arg.name
		}, _);
	});
}

function fnDeclareVariable(type, name, def, isStatic, _) {
	var obj = {
		$: "variable",
		type: type,
		name: name,
		globals: isStatic
	};
	
	fnScopeAdd(name, obj, _);
	
	if(isStatic) {
		var global_name = func_buf.name + ":" + name;
		registerGlobal(type, global_name, def, _);
		obj.addr = getGlobal(global_name).addr;
	} else if(def) {
		func_buf.body += compileExpr({
			$: "assign",
			type: type,
			to: { $: "ref", type: type, ref: name },
			expr: dynCast(def, type, _)
		}, _) + "\n";
	}
}

function fnEnd(body) {
	func_buf.body += body;
	delete func_buf.scope_ctn;
	
	if(func_buf.name === "MAIN") {
		main_func = func_buf;
	} else {
		funcs[func_buf.name] = func_buf;
		funcs_list.push(func_buf);
	}
	
	func_buf = null;
}

function fnCompile(fn) {
	var buffer = [];
	var main_fn = (fn.name === "MAIN");
	
	if(main_fn) {
		buffer.push("ORGANIZATION_BLOCK OB 1\n");
	} else {
		buffer.push("FUNCTION " + fn.id + " : ");
		buffer.push(typeToLIST(fn.type) + "\n");
		if(!/\$/.test(fn.name))
			buffer.push("TITLE = " + fn.name + "\n");
	}
	
	// Dispatch scope symbols
	var args = [];
	var locals = [];
	
	for(var name in fn.scope) {
		var sym = fn.scope[name];
		switch(sym.$) {
			case "argument":
				args.push(sym);
				break;
				
			case "variable":
				if(!sym.globals)
					locals.push(sym);
				break;
				
			case "array": break;
			
			default: throw new Error("Unknown local symbol type: " + sym.$);
		}
	}
	
	// Args
	if(args.length) {
		buffer.push("VAR_INPUT\n");
		args.forEach(function(arg) {
			buffer.push("  " + arg.addr.slice(1) + " : ");
			buffer.push(typeToLIST(arg.type) + " ;\t");
			buffer.push("// (" + arg.name + ")\n");
		});
		buffer.push("END_VAR\n");
	}
	
	// Locals
	if(locals.length || main_fn) {
		buffer.push("VAR_TEMP\n");
		if(main_fn)
			buffer.push("  Default : ARRAY  [1 .. 20] OF BYTE ;\n");
		locals.forEach(function(local) {
			buffer.push("  " + local.addr.slice(1) + " : ");
			buffer.push(typeToLIST(local.type) + " ;\t");
			buffer.push("// (" + local.name + ")\n");
		});
		buffer.push("END_VAR\n");
	}
	
	buffer.push("BEGIN\n");
	var end_label = generateLabel();
	
	fn.body = fn.body
		.replace(/^(\s+)(.*)$/mg, "$2")
		.replace(/^\s*?\n/mg, "")
		.replace(/(\s+)$/, "")
		.replace(/\$return$/mg, "BEU")
		.replace(/\$goto\:([a-zA-Z0-9_]+)$/mg, function(_, label) {
			if(!fn.labels[label])
				throw new Error("Undefined label '" + label + "' in function '" + fn.name + "'");
			return "JU " + fn.labels[label];
		});
	
	var matches = fn.body.match(/^\$([a-z]+)|[^$]\$([a-z]+)/);
	if(matches)
		throw new Error("Incorrect usage of keyword '" + (matches[1] || matches[2]) + "' in function '" + fn.name + "'");
	
	fnOptimize(fn);
	
	fn.body = fn.body
		.replace(/(.)$/mg, "$1;")
		.replace(/^/mg, "        ")
		.replace(/^ +([a-z0-9]{4}:)/mg, "  $1");
	
	buffer.push(fn.body);
	buffer.push("\n");
	if(main_fn) {
		buffer.push("END_ORGANIZATION_BLOCK");
	} else {
		buffer.push("END_FUNCTION");
	}
	return buffer.join("");
}

function fnOptimize(fn) {
	//return;
	
	function RE(expr) {
		return new RegExp(expr, "g");
	}

	var queue = [];
	var transforms = [
		[ /^([a-z0-9]{4}): NOP 0\n([a-z0-9]{4}):/mg,
			function(_, label1, label2) {
				queue.push([RE(label1), label2]);
				return label2 + ":";
			}],
		/*[ /^([a-z0-9]{4}): JU ([a-z0-9]{4})\n/mg,
			function(_, label1, label2) {
				queue.push([RE(label1), label2]);
				return "";
			}],*/
		[ /^([a-z0-9]{4}: )NOP 0\n(([^:\s]+)(\s+.*))?$/mg, "$1$2" ],
		[ /^([a-z0-9]{4}): /mg,
			function(match, label) {
				if(!RE(".+? " + label).test(fn.body))
					return "";
				else
					return match;
			}],
		[ /^(JU|JCN) ([a-z0-9]{4})\n(\2:)/mg, "$3" ],
		[ /^TAK\n([*+][IDR]|[AOX][WD])$/mg, "$1" ],
		[ /^NOT\nJCN (.{4})\nJU (.{4})$/mg, "JCN $2\nJU $1" ],
		[ /^NOT\nJCN /mg, "JC " ],
		[ /([AOX])\(\n\1 (.*)\nNOT\n\)$/mg, "$1N $2" ],
		[ /([AOX])\((\n([^)].*\n)+?)NOT\n\)$/mg, "$1N($2)" ],
		[ /([AOX])\(\n((\1 .*\n)+)\)\n/mg, "$2" ],
		[ /([AOX]N?)\(\nA (.*)\n\)/mg, "$1 $2" ],
		[ /A\(\n(A .*\nF[NP] .*)\n\)/mg, "$1" ],
		[ /T MD 4\n(L P\#.*\nT MD 0\n)L MD 4$/mg, "$1TAK" ],
		[ /^NOP 0|\nNOP 0/g, "" ],
		[ /^([a-z0-9]{4}: )(\/\/.*)$/mg, "$1NOP 0\n$2" ],
		[ /\nBEU$/g, "" ]
	];
	
	function apply(t) {
		fn.body = fn.body.replace(t[0], t[1]);
	}
	
	var old_body;
	do {
		old_body = fn.body;
		transforms.forEach(function(t) {
			apply(t);
			if(queue.length) {
				while(t = queue.shift())
					apply(t);
			}
		});
	} while(old_body !== fn.body);
}

function generateFns() {
	funcs_list.push(main_func);
	
	var fns_buffer = [];
	funcs_list.forEach(function(fn) {
		fns_buffer.push(fnCompile(fn));
	});
	
	console.log(fns_buffer.join("\n\n\n"));
}

//
// Expressions
//
var ir_buffers = {};

function requestIRBuf(type) {
	for(var i = 1; i < 10; ++i) {
		var name = "IR$" + i;
		if(!func_buf.scope[name])
				fnDeclareVariable("dword", name, null, false);
		var addr = func_buf.scope[name].addr;
		if(!ir_buffers[addr])
			return ir_buffers[addr] = addr;
	}
	
	throw new Error("IR-buffer usage overflow");
}

function releaseIRBuf(buf) {
	delete ir_buffers[buf];
}

// Builtins
var builtins = (function() {
	function math_op(op) {
		return ["real", function(push, args, _) {
			push(compileExpr(dynCast(args[0], "real", _), _));
			push(op);
		}]
	}

	return {
		"$ABS": math_op("ABS"),
		"$SQR": math_op("SQR"),
		"$SQRT": math_op("SQRT"),
		"$EXP": math_op("EXP"),
		"$LN": math_op("LN"),
		"$SIN": math_op("SIN"),
		"$COS": math_op("COS"),
		"$TAN": math_op("TAN"),
		"$ASIN": math_op("ASIN"),
		"$ACOS": math_op("ACOS"),
		"$ATAN": math_op("ATAN")
	};
})();

function compileExpr(expr, _) {
	var buffer = [];
	
	function done(last) {
		if(last)
			buffer.push(last);
		return buffer.join("\n");
	}
	
	function push(line) {
		buffer.push(line);
	}
	
	switch(expr.$) {
		case "value":
			switch(expr.type) {
				case "integer":
					switch(expr.c_type) {
						case "byte":
						case "word":
						case "int":
						case "dword":
						case "long":
							return done("L " + compileRawValue(expr.value, expr.c_type));
					
						default:
							return done("L " + expr.value);
					}
				
				case "real":
					return done("L " + compileRawValue(expr.value, "real"));
				
				case "boolean":
					return done(expr.value ? "SET" : "CLR");
			}
			break;
		
		case "assign":
			push(compileExpr(expr.expr, _));
			switch(expr.type) {
				case "bit":
					if(expr.to.$ == "array-ref") { 
						return done("= " + arrayDereference(push, expr.to, false, _));
					} else {
						return done("= " + fnScopeResolve(expr.to.ref, _).addr);
					}
				
				case "byte":
				case "word":
				case "int":
				case "dword":
				case "long":
				case "real":
					if(expr.to.$ == "array-ref") {
						return done("T " + arrayDereference(push, expr.to, true, _));
					} else {
						return done("T " + fnScopeResolve(expr.to.ref, _).addr);
					}
			}
			break;
		
		case "ref":
			switch(expr.type) {
				case "bit":
					return done("A " + fnScopeResolve(expr.ref, _).addr);
				
				case "byte":
				case "word":
				case "int":
				case "dword":
				case "long":
				case "real":
					return done("L " + fnScopeResolve(expr.ref, _).addr);
					
				default:
					error("incorrect usage of symbol: " + expr.ref, _);
			}
			break;
		
		case "array-ref":
			switch(expr.type) {
				case "bit":
					return done("A " + arrayDereference(push, expr, false, _));
				
				case "byte":
				case "word":
				case "int":
				case "dword":
				case "long":
				case "real":
					return done("L " + arrayDereference(push, expr, false, _));
					
				default:
					error("incorrect usage of symbol: " + expr.ref, _);
			}
			break;
		
		case "op":
			switch(expr.op) {
				case "+":
				case "-":
				case "*":
				case "/":
				case "%":
					var buf;
					var complex = isComplex(expr.b);
					
					push(compileExpr(expr.a, _));
					if(complex) {
						buf = requestIRBuf();
						push("T " + buf);
					}
					
					push(compileExpr(expr.b, _));
					
					if(complex) {
						push("L " + buf);
						push("TAK");
						releaseIRBuf(buf);
					}
					
					if(expr.op == "%") {
						switch(expr.type) {
							case "real":
								push("TRUNC");
								
							case "byte":
							case "word":
							case "int":
							case "dword":
							case "long":
								return done("MOD");
						}
					} else {
						switch(expr.type) {
							case "byte":
							case "word":
							case "int":
								return done(expr.op + "I");
							
							case "dword":
							case "long":
								return done(expr.op + "D");
							
							case "real":
								return done(expr.op + "R");
						}
					}
					break;
				
				case "'r":
				case "'f":
					push(compileExpr(expr.a, _));
					var op = expr.op === "'r" ? "FP" : "FN";
					return done(op + " M " + allocBit());
				
				case "!":
					push(compileExpr(expr.a, _));
					return done("NOT");
				
				case "&&":
				case "||":
				case "^^":
					var op;
					switch(expr.op) {
						case "&&": op = "A("; break;
						case "||": op = "O("; break;
						case "^^": op = "X("; break;
					};
					
					push(op);
					push(compileExpr(expr.a, _));
					push(")");
					push(op);
					push(compileExpr(expr.b, _));
					return done(")");
				
				case "<<":
				case ">>":
				case "<<<":
				case ">>>":
					var buf;
					var complex = isComplex(expr.a);
					
					push(compileExpr(expr.b, _));
					if(complex) {
						buf = requestIRBuf();
						push("T " + buf);
					}
					
					push(compileExpr(expr.a, _));
					
					if(complex) {
						push("L " + buf);
						push("TAK");
						releaseIRBuf(buf);
					}
					
					switch(expr.type) {
						case "byte":
						case "word":
							return done(expr.op === "<<" ? "SLW" : "SRW");
							
						case "dword":
							return done(expr.op === "<<" ? "SLD" : "SRD");
						
						case "int":
							return done(expr.op === "<<" ? "SLW" : "SSI");
							
						case "long":
						case "real":
							if(expr.op.length > 2)
								return done(expr.op === "<<" ? "RLD" : "RRD");
							else
								return done(expr.op === "<<" ? "SLD" : "SSD");
					}
				
				case "&":
				case "|":
				case "^":
					var buf;
					var complex = isComplex(expr.b);
					
					push(compileExpr(expr.a, _));
					if(complex) {
						buf = requestIRBuf();
						push("T " + buf);
					}
					
					push(compileExpr(expr.b, _));
					
					if(complex) {
						push("L " + buf);
						push("TAK");
						releaseIRBuf(buf);
					}
					
					var op;
					switch(expr.op) {
						case "&": op = "A"; break;
						case "|": op = "O"; break;
						case "^": op = "X"; break;
					}
					
					switch(expr.type) {
						case "byte":
						case "word":
						case "int":
							return done(op + "W");
						
						case "dword":
						case "long":
						case "real":
							return done(op + "D");
					}
				
				case "<":
				case "<=":
				case ">":
				case ">=":
				case "==":
				case "!=":
					if(expr.a.type == "bit") {
						switch(expr.op) {
							case "==":
							case "!=":
								push("X(");
								push(compileExpr(expr.a, _));
								push(")");
								push(expr.op == "==" ? "XN(" : "X(");
								push(compileExpr(expr.b, _));
								return done(")");
						}
						break;
					}
				
					var buf;
					var complex = isComplex(expr.b);
					
					push(compileExpr(expr.a, _));
					if(complex) {
						buf = requestIRBuf();
						push("T " + buf);
					}
					
					push(compileExpr(expr.b, _));
					
					if(complex) {
						push("L " + buf);
						push("TAK");
						releaseIRBuf(buf);
					}
					
					var op;
					switch(expr.op) {
						case "<":  op = "<"; break;
						case "<=": op = "<="; break;
						case ">":  op = ">"; break;
						case ">=": op = ">="; break;
						case "==": op = "=="; break;
						case "!=": op = "<>"; break;
					}
					
					switch(expr.a.type) {
						case "byte":
						case "word":
						case "int":
							return done(op + "I");
						
						case "dword":
						case "long":
							return done(op + "D");
						
						case "real":
							return done(op + "R");
					}
			}
			break;
		
		case "cast":
			push(compileExpr(expr.expr, _));
			
			function bool2int(type) {
				var else_label = generateLabel();
				var end_label = generateLabel();
				push("JCN " + else_label);
				push("L " + compileRawValue(1, type));
				push("JU " + end_label);
				push(else_label + ": L " + compileRawValue(0, type));
				push(end_label + ": NOP 0");
			}
			
			switch(expr.type) {
				case "bit":
					push(expr.expr.type == "real" ? "L " + compileRawValue(0, "real") : "L B#16#0");
					switch(expr.expr.type) {
						case "byte":
						case "word":
						case "int":
							return done("<>I");
						
						case "dword":
						case "long":
							return done("<>D");
						
						case "real":
							return done("<>R");
					}
					break;
				
				case "word":
				case "dword":
					switch(expr.expr.type) {
						case "bit":
							bool2int(expr.type);
							return done();
							
						case "byte":
						case "word":
						case "dword":
						case "int":
						case "long":
						case "real":
							// Already in the accumulator
							return done();
					}
					break;
				
				case "byte":
				case "int":
					switch(expr.expr.type) {
						case "bit":
							bool2int(expr.type);
							return done();
							
						case "byte":
						case "word":
						case "int":
						case "dword":
						case "long":
							// Already in the accumulator
							return done();
						
						case "real":
							return done("TRUNC");
					}
					break;
				
				case "long":
					switch(expr.expr.type) {
						case "bit":
							bool2int(expr.type);
							return done();
						
						case "byte":
						case "word":
						case "dword":
							// Already in the accumulator
							return done();
						
						case "real":
							return done("TRUNC");
						
						case "int":
							return done("ITD");
					}
					break;
					
				case "real":
					switch(expr.expr.type) {
						case "bit":
							bool2int(expr.type);
							return done();
						
						case "byte":
						case "word":
						case "int":
							push("ITD");
						
						case "dword":
						case "long":
							return done("DTR");
					}
					break;
			}
			break;
		
		case "call":
			if(expr.fn[0] == "$") {
				builtins[expr.fn][1](push, expr.args, _)
				return done();
			}
		
			var fn = getSymbol(expr.fn);
			
			if(fn.$ !== "function")
				error("calling a non-function symbol: " + expr.fn, _);
			
			if(expr.args.length != fn.entry.args.length)
				error("parameters count mismatch", _);
			
			var args = [];
			var allocated = {};
			
			expr.args.forEach(function(arg, i) {
				var type = fn.entry.args[i].type;
				var ca_name;
				var j = 0;
				do {
					ca_name = "CA$" + type + j++;
				} while(allocated[ca_name]);
				allocated[ca_name] = true;
				
				if(!func_buf.scope[ca_name])
					fnDeclareVariable(type, ca_name, null, false);
					
				push(compileExpr({ $: "assign", type: type, to: { $: "ref", type: type, ref: ca_name }, expr: dynCast(arg, type, _) }));
				args.push(fn.entry.scope[fn.entry.args[i].name].addr.slice(1) + " := " + func_buf.scope[ca_name].addr);
			});
			
			if(fn.type !== "void") {
				var ret_val_name = "RV$" + fn.type;
				if(!func_buf.scope[ret_val_name])
					fnDeclareVariable(fn.type, ret_val_name, null, false);
				args.unshift("RET_VAL := " + func_buf.scope[ret_val_name].addr);
			}
			
			var args_string = "";
			if(args.length) {
				args_string = " (" + args.join(", ") + ")";
			}
			
			push("CALL " + fn.id + args_string)
			
			if(fn.type !== "void")
				push(compileExpr({ $: "ref", type: fn.type, ref: "RV$" + fn.type }));
				
			return done();
        
        case "list":
            return done(expr.code);
	}
	
	error("unable to compile expression:\n" + JSON.stringify(expr, null, 4), _);
}

function isComplex(expr) {
	if(expr.$ === "cast")
		return isComplex(expr.expr);
	
	switch(expr.$) {
		case "value":
		case "ref":
			return false;
		
		default:
			return true;
	}
}

function validateCase(type, value, _) {
	if(value > 255)
		error("switch-case table overflow (limit is 255)", _);
}

function operationType(op, a, b, _) {
	if(a.$ === "value" || b.$ === "value") {
		if(a.$ === "value" && b.$ === "value") {
			switch(a.type) {
				case "boolean": return "bit";
				case "integer": return "long";
				case "real":    return "real";
				default:
					error("Unhandled operand type: " + a.type);
			}
		} else {
			return a.$ === "value" ? b.type : a.type;
		}
	}
	
	if(a.type !== b.type)
		error("operation types mismatch: " + a.type + " " + b.type, _);
	
	return a.type;
}

%}

/* lexical grammar */
%lex

%%
\s+                                           /* skip whitespace */
\/\/.*                                        /* skip comments */
"/*"(.|\n|\r)*?"*/"                           /* skip comments */

"``"(.|\n|\r)*?"``"                           return 'LIST_CODE';
"`"(.|\n|\r)*?"`"                             return 'LIST_EXPRESSION';
"#".*                                         return 'LIST_COMMENT';

([0-9][0-9_]*)?\.[0-9_]+\b                    return 'REAL_CONSTANT';
[0-9][0-9_]*\b                                return 'DEC_CONSTANT';
0[xX][0-9A-Fa-f_]+?\b                         return 'HEX_CONSTANT';
0[bB][01_]+?\b                                return 'BIN_CONSTANT';

"true"                                        return 'TRUE';
"false"                                       return 'FALSE';

"case"                                        return 'CASE';
"default"                                     return 'DEFAULT';
"if"                                          return 'IF';
"else"                                        return 'ELSE';
"switch"                                      return 'SWITCH';
"while"                                       return 'WHILE';
"do"                                          return 'DO';
"for"                                         return 'FOR';
"goto"                                        return 'GOTO';
"continue"                                    return 'CONTINUE';
"break"                                       return 'BREAK';
"return"                                      return 'RETURN';
"static"                                      return 'STATIC';
"block"                                       return 'BLOCK';

"->"                                          return 'RANGE_OPERATOR';

":r"                                          return 'RISING';
":f"                                          return 'FALLING';
"++"                                          return '++';
"--"                                          return '--';

"*="                                          return '*=';
"/="                                          return '/=';
"+="                                          return '+=';
"-="                                          return '-=';
"%="                                          return '%=';
"<<="                                         return '<<=';
">>="                                         return '>>=';

"<<<"                                         return '<<<';
">>>"                                         return '>>>';
"<<"                                          return '<<';
">>"                                          return '>>';
"<="                                          return '<=';
">="                                          return '>=';
"=="                                          return '==';
"!="                                          return '!=';

"&&"                                          return '&&';
"and"                                         return '&&';
"||"                                          return '||';
"or"                                          return '||';
"^^"                                          return '^^';
"xor"                                         return '^^';

"&="                                          return '&=';
"&"                                           return '&';
"|="                                          return '|=';
"|"                                           return '|';
"^="                                          return '^=';
"^"                                           return '^';

"!"                                           return '!';
"not"                                         return '!';
"*"                                           return '*';
"/"                                           return '/';
"%"                                           return '%';
"-"                                           return '-';
"+"                                           return '+';
"("                                           return '(';
")"                                           return ')';
"["                                           return '[';
"]"                                           return ']';
"{"                                           return '{';
"}"                                           return '}';
","                                           return ',';
":"                                           return ':';
";"                                           return ';';
"="                                           return '=';
"<"                                           return '<';
">"                                           return '>';
"~"                                           return '~';

\@\s*[IQM]([0-9]+\.[0-7]|[BWD][0-9]+)\b       return 'EXTERNAL_POINTER';
[a-zA-Z_$][a-zA-Z_0-9]*\b                     return 'IDENTIFIER';

<<EOF>>                                       return 'EOF';
.                                             return 'INVALID';

/lex

/* operator associations and precedence */

%left IF_STMT
%left ELSE

%left  ','
%rigth '=' '+=' '-=' '*=' '/=' '%=' '<<=' '>>=' '&=' '^=' '|='
%left  '||'
%left  '^^'
%left  '&&'
%left  '|'
%left  '^'
%left  '&'
%left  '==' '!='
%left  '<' '<=' '>' '>='
%left  '<<' '>>' '<<<' '>>>'
%left  '+' '-'
%left  '*' '/' '%'
%left  CAST_OP
%left  '!'
%left  'RISING' 'FALLING'
%rigth '~' UMINUS
%left  '++' '--'

%start program

%% /* language grammar */

program
	: program_units EOF
		{
			if(!main_func)
				throw new Error("Reached EOF without a main function defined");
			
			generateDbs();
			generateFns();
			
			//console.error(symbols);
		}
	| EOF
	;

program_units
	: program_unit
	| program_units program_unit
	;
	
program_unit
	: external_declaration
	| struct_declaration
	| global_variable_declaration
	| global_array_declaration
	| function_declaration
    | block_declaration
	;
    
block_declaration
    : BLOCK EXTERNAL_MEMORY_POINTER RANGE_OPERATOR EXTERNAL_MEMORY_POINTER ';'
        {
            var begin = parseInt($2.slice(2));
            var end = parseInt($4.slice(2));
            registerMemoryBytes(begin, (end - begin) + 1);
        }
    ;

external_declaration
	: IDENTIFIER normalized_identifier EXTERNAL_POINTER ';'
		{ registerExternal(normalizeType($1), $2, $3, @1); }
	| IDENTIFIER normalized_identifier '[' constant_integer ']' EXTERNAL_POINTER ';'
		{ registerExternalArray(normalizeType($1), $2, $4, $6, @1); }
	;

global_variable_declaration
	: variable_declaration
		{ registerGlobal($1[0], $1[1], $1[2], @1); }
	;

variable_declaration
	: IDENTIFIER normalized_identifier ';'
		{ $$ = [normalizeType($1), $2]; }
	| IDENTIFIER normalized_identifier '=' constant_expression ';'
		{ $$ = [normalizeType($1), $2, $4]; }
	;

global_array_declaration
	: array_declaration
		{
			registerSymbol($1[1], {
				$: "array",
				type: $1[0],
				length: $1[2],
				twidth: $1[3],
				offset: $1[4]
			}, @1);
		}
	;
	
array_declaration
	: IDENTIFIER normalized_identifier '[' constant_integer ']' ';'
		{
			if($4 < 1)
				error("Zero-sized array are not allowed", @1);
				
			$1 = normalizeType($1);
			var twidth = typeWidth($1);
			
			var offset;
			if(twidth) {
				offset = allocMemory(twidth * $4);
			} else {
				offset = allocMemory(Math.floor(($4 - 1) / 8) + 1);
			}
			
			$$ = [$1, $2, $4, twidth, offset];
		}
	;

function_declaration
	: function_definition '{' function_body '}'
		{ fnEnd($3.join("\n")) }
	| function_definition '{' '}'
		{ fnEnd("") }
	;
	
struct_declaration
	: STRUCT normalized_identifier '{' struct_definition '}'
		{
			
		}
	;

struct_definition
	: struct_member_definition
		{ $$ = [$1]; }
	| struct_definition struct_member_definition
		{ $1.push($2); }
	;

struct_member_definition
	: type normalized_identifier ';'
		{ $$ = [$2, $1, null, @1]; }
	| type normalized_identifier '=' constant_expression ';'
		{ $$ = [$2, $1, $4, @1]; }
	;

function_definition
	: function_definition_inner
		{ fnBegin($1, @1); }
	;
	
function_definition_inner
	: IDENTIFIER normalized_identifier '(' arguments_definition ')'
		{
			$1 = normalizeType($1);
			if($2 === "MAIN") {
				if($1 !== "void" || $4.length)
					error("main function must be declared 'void main()'", @1);
			}
			
			$$ = { type: $1, name: $2, args: $4 };
		}
	| normalized_identifier
		{ $$ = { type: "void", name: $1, args: [] }; }
	;

arguments_definition
	: argument
		{ $$ = [$1]; }
	| arguments_definition ',' argument
		{ $1.push($3); }
	|
		{ $$ = []; }
	;

argument
	: IDENTIFIER normalized_identifier
		{ $$ = { type: normalizeType($1), name: $2 }; }
	;

function_body
	: local_declaration_list statements_list
		{ $$ = $2; }
	| local_declaration_list
		{ $$ = []; }
	| statements_list
	;

local_declaration_list
	: local_variable_declaration
	| local_declaration_list local_variable_declaration
	;
	
local_variable_declaration
	: variable_declaration
		{ fnDeclareVariable($1[0], $1[1], $1[2], false, @1); }
	| STATIC variable_declaration
		{ fnDeclareVariable($2[0], $2[1], $2[2], true, @2); }
	| local_array_declaration
		{ 
			fnScopeAdd($1[1], {
				$: "array",
				type: $1[0],
				length: $1[2],
				twidth: $1[3],
				offset: $1[4]
			}, @1);
		}
	;

local_array_declaration
	: array_declaration
	| STATIC array_declaration
		{ $$ = $2; }
	;
	
statements_list
	: statement
		{ $$ = $1 ? [$1] : []; }
	| statements_list statement
		{ if($2) $1.push($2); $$ = $1; }
	;
	
statement
	: block_statement
	| expression_statement
		{ $$ = compileExpr($1, @1); }
	| if_statement %prec IF_STMT
		{
			var buffer = [];
			var else_label = generateLabel();
			var end_label = generateLabel();
			
			buffer.push(compileExpr(dynCast($1.expr, "bit", @1)));
			buffer.push("JCN " + ($1.otherwise ? else_label : end_label));
			
			if($1.then)
				buffer.push($1.then);
				
			if($1.otherwise) {
				buffer.push("JU " + end_label);
				buffer.push(else_label + ": " + $1.otherwise);
			}
			
			buffer.push(end_label + ": NOP 0");
			$$ = buffer.join("\n");
		}
	| switch_statement
		{
			var buffer = [];
			var end_label = generateLabel();
			var catch_label = generateLabel();
			var default_label = $1.cases.map["default"] ? $1.cases.map["default"].label : end_label;
			
			buffer.push(compileExpr(dynCast($1.expr, "byte", @1)));
			buffer.push("JL " + catch_label);
			
			var max_case = Object.keys($1.cases.map).reduce(function(a, b) {
				if(b === "default")
					return a;
				else
					return parseInt(b) > a ? b : a;
			}, -1);
			
			for(var i = 0; i <= max_case; ++i) {
				if($1.cases.map[i]) {
					buffer.push("JU " + $1.cases.map[i].label);
				} else {
					buffer.push("JU " + default_label);
				}
			}
			
			buffer.push(catch_label + ": JU " + default_label);
			
			$1.cases.list.forEach(function(c) {
				buffer.push(c.label + ": " + (c.body.length
					? c.body.join("\n").replace(/\$break/g, "JU " + end_label)
					: "NOP 0"));
			});
			
			buffer.push(end_label + ": NOP 0");
			$$ = buffer.join("\n");
		}
	| loop_statement
	| control_statement
	| LIST_CODE
		{
			$$ = $1.slice(2, -2).replace(/\#([a-zA-Z_][a-zA-Z0-9_]*)/mg, function(_, sym) {
				return fnScopeResolve(sym.toUpperCase(), @1).addr;
			});
		}
	| LIST_COMMENT
		{ $$ = "//" + $1; }
	| normalized_identifier ':' statement
		{
			if(func_buf.labels[$1])
				error("duplicate label: " + $1, @1);
			$$ = (func_buf.labels[$1] = generateLabel()) + ": " + $3;
		}
	| GOTO normalized_identifier ';'
		{
			$$ = "$goto:" + $2
		}
	| ';'
		{ $$ = "NOP 0"; }
	;
	
block_statement
	: '{' statements_list '}'
		{ $$ = $2.join("\n"); }
	| '{' '}'
		{ $$ = null; }
	;

expression_statement
	: expression ';'
	;
	
expression
	: assignment_expression
	| assign_operation_expression
		{
			$$ = {
				$: "assign",
				type: $1.ref.type,
				to: $1.ref,
				expr: {
					$: "op",
					type: $1.ref.type,
					op: $1.op,
					a: $1.ref,
					b: dynCast($1.operand, $1.ref.type, @1)
				}
			};
		}
	| sub_expression
	;

sub_expression
	: '(' expression ')'
		{ $$ = $2; }
	| cast_expression
	| constant_expression
	| reference_expression
	| binary_operation_expression
		{
			var t = operationType($1.op, $1.a, $1.b, @1);
			if(!$1.type)
				$1.type = t;
			$1.a = dynCast($1.a, t, @1);
			$1.b = dynCast($1.b, t, @1);
		}
	| logical_operation_expression
	| shift_operation_expression
		{ $1.type = ($1.a.$ == "value") ? $1.a.c_type || "byte" : $1.a.type; }
	| unary_operation_expression
	| increment_operation_expression
		{
			$$ = {
				$: "assign",
				type: $1.ref.type,
				to: { $: "ref", type: $1.ref.type, ref: $1.ref.ref },
				expr: {
					$: "op",
					type: $1.ref.type,
					op: $1.op,
					a: $1.ref,
					b: dynCast({ $: "value", type: "integer", value: 1 }, $1.ref.type, @1)
				}
			};
		}
	| call_expression
		{
			if($1.fn[0] == "$") {
				if(!builtins[$1.fn])
					error("undefined built-in: " + $1.fn, @1);
				$1.type = builtins[$1.fn][0];
			} else {
				$1.type = getSymbol($1.fn).type;
			}
		}
    | LIST_EXPRESSION
        { $$ = { $: "list", type: "polymorphic", code: $1.slice(1, -1).replace(/;/g, "\n").replace(/\#([a-zA-Z_][a-zA-Z0-9_]*)/mg, function(_, sym) {
            return fnScopeResolve(sym.toUpperCase(), @1).addr;
        }) }; }
	;

assignment_expression
	: reference_expression '=' expression
		{
			$$ = { $: "assign", type: $1.type, to: $1, expr: dynCast($3, $1.type, @1) };
		}
	;

reference_expression
	: normalized_identifier
		{
			if(fnScopeResolve($1, @1).$ !== "variable" && fnScopeResolve($1, @1).$ !== "external" && fnScopeResolve($1, @1).$ !== "argument")
				error("reference must be a variable symbol", @1);
			$$ = { $: "ref", type: resolveType($1, @1), ref: $1 };
		}
	| normalized_identifier '[' expression ']'
		{
			if(fnScopeResolve($1, @1).$ !== "array" && fnScopeResolve($1, @1).$ !== "external-array")
				error("dereferencing base must be an array symbol", @1);
			$$ = { $: "array-ref", type: resolveType($1, @1), ref: $1, index: $3 };
		}
	;

if_statement
	: IF '(' expression ')' statement
		{ $$ = { expr: $3, then: $5 }; }
	| if_statement ELSE statement %prec ELSE
		{ $1.otherwise = $3; }
	;

loop_statement
	: while_statement
		{
			var buffer = [];
			var loop_label = generateLabel();
			var cond_label = generateLabel();
			var end_label  = generateLabel();
			
			var cond = cond_label + ": "
				+ compileExpr(dynCast($1.cond, "bit", @1)) + "\n"
				+ ($1.do_while ? "JC " + loop_label : "JCN " + end_label);
			
			if(!$1.do_while) buffer.push(cond);
			
			var loop = $1.loop
				.replace(/\$break/g, "JU " + end_label)
				.replace(/\$continue/g, "JU " + cond_label);
				
			buffer.push(loop_label + ": " + loop);
			
			if(!$1.do_while)
				buffer.push("JU " + cond_label);
			else
				buffer.push(cond);
			
			buffer.push(end_label + ": NOP 0");
			$$ = buffer.join("\n");
		}
	| for_statement
		{
			var buffer = [];
			if($1.init) buffer.push(compileExpr($1.init));
			
			var loop_label = generateLabel();
			var cond_label = $1.cond ? generateLabel() : loop_label;
			var inc_label  = $1.inc ? generateLabel() : cond_label;
			var end_label  = generateLabel();
			
			if($1.cond) {
				buffer.push(cond_label + ": "
					+ compileExpr(dynCast($1.cond, "bit", @1)) + "\n"
					+ "JCN " + end_label);
			}
			
			var loop;
			if($1.loop) {
				loop = $1.loop
					.replace(/\$break/g, "JU " + end_label)
					.replace(/\$continue/g, "JU " + inc_label);
			} else {
				loop = "NOP 0";
			}
			buffer.push(loop_label + ": " + loop);
			
			if($1.inc) buffer.push(inc_label + ": " + compileExpr($1.inc))
			
			buffer.push("JU " + cond_label);
			buffer.push(end_label + ": NOP 0");
			$$ = buffer.join("\n");
		}
	;
	
while_statement
	: WHILE '(' expression ')' statement
		{ $$ = { cond: $3, loop: $5, do_while: false }; }
	| DO statement WHILE '(' expression ')' ';'
		{ $$ = { cond: $5, loop: $2, do_while: true }; }
	;

for_statement
	: FOR '(' expression ';' expression ';' expression ')' statement
		{ $$ = { init: $3, cond: $5, inc: $7, loop: $9 }; }
	| FOR '(' ';' expression ';' expression ')' statement
		{ $$ = { init: null, cond: $4, inc: $6, loop: $8 }; }
	| FOR '(' expression ';' ';' expression ')' statement
		{ $$ = { init: $3, cond: null, inc: $6, loop: $8 }; }
	| FOR '(' expression ';' expression ';' ')' statement
		{ $$ = { init: $3, cond: $5, inc: null, loop: $8 }; }
	| FOR '(' expression ';' ';' ')' statement
		{ $$ = { init: $3, cond: null, inc: null, loop: $7 }; }
	| FOR '(' ';' expression ';' ')' statement
		{ $$ = { init: null, cond: $4, inc: null, loop: $7 }; }
	| FOR '(' ';' ';' expression ')' statement
		{ $$ = { init: null, cond: null, inc: $5, loop: $7 }; }
	| FOR '(' ';' ';' ')' statement
		{ $$ = { init: null, cond: null, inc: null, loop: $6 }; }
	;
	
switch_statement
	: SWITCH '(' expression ')' '{' cases_list '}'
		{ $$ = { expr: $3, cases: $6 }; }
	;

cases_list
	: case_unit
		{ $$ = { map: {}, list: [] }; $$.list.push($$.map[$1.key] = $1); }
	| cases_list case_unit
		{
			if($$.map[$2.key])
				error("duplicated case: " + $2.key, @2);
			$$.list.push($$.map[$2.key] = $2);
		}
	;

case_unit
	: CASE constant_integer ':' statements_list
		{
			validateCase($2, @1);
			$$ = { key: $2, body: $4, label: generateLabel() };
		}
	| CASE constant_integer ':'
		{
			validateCase($2, @1);
			$$ = { key: $2, body: [], label: generateLabel() };
		}
	| DEFAULT ':' statements_list
		{ $$ = { key: "default", body: $3, label: generateLabel() }; }
	| DEFAULT ':'
		{ $$ = { key: "default", body: [], label: generateLabel() }; }
	;

control_statement
	: BREAK ';'
		{ $$ = "$break"; }
	| CONTINUE ';'
		{ $$ = "$continue"; }
	| RETURN ';'
		{ $$ = "$return"; }
	| RETURN expression ';'
		{
			$$ = [
				compileExpr({
					$: "assign",
					type: func_buf.type,
					to: { $: "ref", type: func_buf.type, ref: "RET_VAL" },
					expr: dynCast($2, func_buf.type, @1)
				}, @1),
				"$return"
			].join("\n");
		}
	;

normalized_identifier
	: IDENTIFIER
		{ $$ = $1.toUpperCase(); }
	;

type
	: IDENTIFIER
	;

cast_expression
	: '<' IDENTIFIER '>' sub_expression %prec CAST_OP
		{ $$ = dynCast($4, normalizeType($2), @1); }
	;
	
binary_operation_expression
	: sub_expression '+' sub_expression
		{ $$ = { $: "op", op: "+", a: $1, b: $3 }; }
	| sub_expression '-' sub_expression
		{ $$ = { $: "op", op: "-", a: $1, b: $3 }; }
	| sub_expression '*' sub_expression
		{ $$ = { $: "op", op: "*", a: $1, b: $3 }; }
	| sub_expression '/' sub_expression
		{ $$ = { $: "op", op: "/", a: $1, b: $3 }; }
	| sub_expression '%' sub_expression
		{ $$ = { $: "op", op: "%", a: $1, b: $3 }; }
	| sub_expression '&' sub_expression
		{ $$ = { $: "op", op: "&", a: $1, b: $3 }; }
	| sub_expression '|' sub_expression
		{ $$ = { $: "op", op: "|", a: $1, b: $3 }; }
	| sub_expression '^' sub_expression
		{ $$ = { $: "op", op: "^", a: $1, b: $3 }; }
	| sub_expression '<' sub_expression
		{ $$ = { $: "op", op: "<", type: "bit", a: $1, b: $3 }; }
	| sub_expression '<=' sub_expression
		{ $$ = { $: "op", op: "<=", type: "bit", a: $1, b: $3 }; }
	| sub_expression '>' sub_expression
		{ $$ = { $: "op", op: ">", type: "bit", a: $1, b: $3 }; }
	| sub_expression '>=' sub_expression
		{ $$ = { $: "op", op: ">=", type: "bit", a: $1, b: $3 }; }
	| sub_expression '==' sub_expression
		{ $$ = { $: "op", op: "==", type: "bit", a: $1, b: $3 }; }
	| sub_expression '!=' sub_expression
		{ $$ = { $: "op", op: "!=", type: "bit", a: $1, b: $3 }; }
	;
	
shift_operation_expression
	: sub_expression '<<' sub_expression
		{ $$ = { $: "op", op: "<<", a: $1, b: dynCast($3, "byte", @3) }; }
	| sub_expression '>>' sub_expression
		{ $$ = { $: "op", op: ">>", a: $1, b: dynCast($3, "byte", @3) }; }
	| sub_expression '<<<' sub_expression
		{ $$ = { $: "op", op: "<<<", a: dynCast($1, "long", @1), b: dynCast($3, "byte", @3) }; }
	| sub_expression '>>>' sub_expression
		{ $$ = { $: "op", op: ">>>", a: dynCast($1, "long", @1), b: dynCast($3, "byte", @3) }; }
	;
	
logical_operation_expression
	: sub_expression '&&' sub_expression
		{ $$ = { $: "op", op: "&&", type: "bit", a: dynCast($1, "bit", @1), b: dynCast($3, "bit", @3) }; }
	| sub_expression '||' sub_expression
		{ $$ = { $: "op", op: "||", type: "bit", a: dynCast($1, "bit", @1), b: dynCast($3, "bit", @3) }; }
	| sub_expression '^^' sub_expression
		{ $$ = { $: "op", op: "^^", type: "bit", a: dynCast($1, "bit", @1), b: dynCast($3, "bit", @3) }; }
	;

unary_operation_expression
	: sub_expression RISING
		{ $$ = { $: "op", type: "bit", op: "'r", a: dynCast($1, "bit", @1) }; }
	| sub_expression FALLING
		{ $$ = { $: "op", type: "bit", op: "'f", a: dynCast($1, "bit", @1) }; }
	| '!' sub_expression %prec '!'
		{ $$ = { $: "op", type: "bit", op: "!", a: dynCast($2, "bit", @1) }; }
	;

increment_operation_expression
	: '++' reference_expression
		{ $$ = { op: "+", ref: $2 }; }
	| '--' reference_expression
		{ $$ = { op: "-", ref: $2 }; }
	;

assign_operation_expression
	: reference_expression '+=' sub_expression
		{ $$ = { op: "+", ref: $1, operand: $3 }; }
	| reference_expression '-=' sub_expression
		{ $$ = { op: "-", ref: $1, operand: $3 }; }
	| reference_expression '*=' sub_expression
		{ $$ = { op: "*", ref: $1, operand: $3 }; }
	| reference_expression '/=' sub_expression
		{ $$ = { op: "/", ref: $1, operand: $3 }; }
	| reference_expression '%=' sub_expression
		{ $$ = { op: "%", ref: $1, operand: $3 }; }
	| reference_expression '<<=' sub_expression
		{ $$ = { op: "<<", ref: $1, operand: $3 }; }
	| reference_expression '>>=' sub_expression
		{ $$ = { op: ">>", ref: $1, operand: $3 }; }
	| reference_expression '&=' sub_expression
		{ $$ = { op: "&", ref: $1, operand: $3 }; }
	| reference_expression '|=' sub_expression
		{ $$ = { op: "|", ref: $1, operand: $3 }; }
	| reference_expression '^=' sub_expression
		{ $$ = { op: "^", ref: $1, operand: $3 }; }
	;
	
call_expression
	: normalized_identifier '(' ')'
		{ $$ = { $: "call", fn: $1, args: [] }; }
	|  normalized_identifier '(' call_argument_list ')'
		{ $$ = { $: "call", fn: $1, args: $3 }; }
	;

call_argument_list
	: expression
		{ $$ = [$1]; }
	| call_argument_list ',' expression
		{ $1.push($3); }
	;
	
constant_expression
	: DEC_CONSTANT
		{ $$ = { $: "value", type: "integer", value: parseInt($1.replace(/_/g, ""), 10) }; }
	| HEX_CONSTANT
		{ $$ = { $: "value", type: "integer", value: parseInt($1.slice(2).replace(/_/g, ""), 16) }; }
	| BIN_CONSTANT
		{ $$ = { $: "value", type: "integer", value: parseInt($1.slice(2).replace(/_/g, ""), 2) }; }
	| REAL_CONSTANT
		{ $$ = { $: "value", type: "real", value: ($1.replace(/_/g, "")) * 1 }; }
	| boolean_literal
		{ $$ = { $: "value", type: "boolean", value: $1 }; }
	;
	
constant_integer
	: DEC_CONSTANT
		{ $$ = parseInt($1, 10); }
	;

boolean_literal
	: TRUE
		{ $$ = true; }
	| FALSE
		{ $$ = false; }
	;
	