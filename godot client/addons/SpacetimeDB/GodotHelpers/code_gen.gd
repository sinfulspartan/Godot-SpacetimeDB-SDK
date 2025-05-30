@tool
class_name Codegen extends Resource
var HIDE_PRIVATE_TABLES: = true
var HIDE_SCHEDULED_REDUCERS: = true

const PLUGIN_DATA_FOLDER = "spacetime_data"
const CODEGEN_FOLDER = "schema"
const REQUIRED_FOLDERS_IN_CODEGEN_FOLDER = ["tables", "spacetime_types"]
const OPTION_CLASS_NAME = "Option" 

var CONFIG: Dictionary = {
	"config_version": 2,
	"hide_scheduled_reducers": HIDE_SCHEDULED_REDUCERS,
	"hide_private_tables": HIDE_PRIVATE_TABLES
}

const GDNATIVE_TYPES := {
	"I8": "int",
	"I16": "int",
	"I32": "int",
	"I64": "int",
	"U8": "int",
	"U16": "int",
	"U32": "int",
	"U64": "int",
	"F32": "float",
	"F64": "float",
	"String": "String",
	"Vector4": "Vector4",
	"Vector4I": "Vector4i",
	"Vector3": "Vector3",
	"Vector3I": "Vector3i",
	"Vector2": "Vector2",
	"Vector2I": "Vector2i",
	"Plane": "Plane",
	"Color": "Color",
	"Quaternion": "Quaternion",
	"Bool": "bool",
	"Nil": "null", # For Option<()>
}
var TYPE_MAP := {
	"__identity__": "PackedByteArray",
	"__connection_id__": "PackedByteArray",
	"__timestamp_micros_since_unix_epoch__": "int",
	"__time_duration_micros__": "int",
}
var META_TYPE_MAP := {
	"I8": "i8",
	"I16": "i16",
	"I32": "i32",
	"I64": "i64",
	"U8": "u8",
	"U16": "u16",
	"U32": "u32",
	"U64": "u64",
	"F32": "f32",
	"F64": "f64",
	"String": "string", # For BSATN, e.g. option_string or vec_String (if Option<Array<String>>)
	"Bool": "bool",   # For BSATN, e.g. option_bool
	"Nil": "nil",     # For BSATN Option<()>
	"__identity__": "identity",
	"__connection_id__": "connection_id",
	"__timestamp_micros_since_unix_epoch__": "i64",
	"__time_duration_micros__": "i64",
}

func _init() -> void:
	TYPE_MAP.merge(GDNATIVE_TYPES)
	if not FileAccess.file_exists("res://%s/%s" %[PLUGIN_DATA_FOLDER, "codegen_config.json"]):
		var file = FileAccess.open("res://%s/%s" %[PLUGIN_DATA_FOLDER , "codegen_config.json"], FileAccess.WRITE)
		file.store_string(JSON.stringify(CONFIG, "\t", false))
		file.close()
	var file = FileAccess.open("res://%s/%s" %[PLUGIN_DATA_FOLDER , "codegen_config.json"], FileAccess.READ)
	var config = JSON.parse_string(file.get_as_text())
	file.close()
	HIDE_SCHEDULED_REDUCERS = config.get("hide_scheduled_reducers", HIDE_SCHEDULED_REDUCERS)
	HIDE_PRIVATE_TABLES = config.get("hide_private_tables", HIDE_PRIVATE_TABLES)
	update_config(config)
	
func update_config(config: Dictionary) -> void:
	var version = config.get("config_version")
	if version < CONFIG.get("config_version"):
		var file = FileAccess.open("res://%s/%s" %[PLUGIN_DATA_FOLDER , "codegen_config.json"], FileAccess.WRITE)
		file.store_string(JSON.stringify({
			"config_version": 2,
			"hide_scheduled_reducers": HIDE_SCHEDULED_REDUCERS,
			"hide_private_tables": HIDE_PRIVATE_TABLES
		}, "\t", false))
		file.close()

func _on_request_completed(json_string: String, module_name: String) -> Array[String]:
	var json = JSON.parse_string(json_string)
	var schema: Dictionary = parse_schema(json, module_name)
	if schema.is_empty():
		printerr("Schema parsing failed for module: %s. Aborting codegen for this module." % module_name)
		return []
		
	if not DirAccess.dir_exists_absolute("res://%s/%s" %[PLUGIN_DATA_FOLDER, "codegen_debug"]):
		DirAccess.make_dir_recursive_absolute("res://%s/%s" %[PLUGIN_DATA_FOLDER , "codegen_debug"])
	
	for folder in REQUIRED_FOLDERS_IN_CODEGEN_FOLDER:
		if not DirAccess.dir_exists_absolute("res://%s/%s/%s" %[PLUGIN_DATA_FOLDER, CODEGEN_FOLDER, folder]):
			DirAccess.make_dir_recursive_absolute("res://%s/%s/%s" %[PLUGIN_DATA_FOLDER, CODEGEN_FOLDER, folder])
			
	var file = FileAccess.open("res://%s/%s/readme.txt" %[PLUGIN_DATA_FOLDER , "codegen_debug"], FileAccess.WRITE)
	file.store_string("You can delete this directory and files. It's only used for codegen debugging.")
	file = FileAccess.open("res://%s/%s/schema_%s.json" % [PLUGIN_DATA_FOLDER, "codegen_debug", module_name], FileAccess.WRITE)
	file.store_string(JSON.stringify(schema, "\t", false))
	var generated_files := build_gdscript_from_schema(schema)
	return generated_files

func build_gdscript_from_schema(schema: Dictionary) -> Array[String]:
	var module_name: String = schema.get("module", null)
	var generated_files: Array[String] = []
	
	for type_def in schema.get("types", []): 
		if type_def.has("gd_native"): continue
		if type_def.has("struct"):
			var folder_path: String = "spacetime_types"
			var generated_table_names: Array[String] 
			if type_def.has("table_names"):
				if not type_def.has("primary_key_name"): continue
				if HIDE_PRIVATE_TABLES and not type_def.get("is_public", []).has(true): 
					Spacetime.print_log("Skipping private table struct %s" % type_def.get("name", ""))
					continue
				var table_names_arr: Array = type_def.get("table_names", []) 
				folder_path = "tables"
				for i in table_names_arr.size():
					var tbl_name: String = table_names_arr[i] 
					if HIDE_PRIVATE_TABLES and not type_def.get("is_public", [])[i]:  
						Spacetime.print_log("Skipping private table %s" % tbl_name)
						continue
					generated_table_names.append(tbl_name)
					
			var content: String = generate_struct_gdscript(type_def, module_name, generated_table_names)
			var output_file_name: String = "%s_%s.gd" % \
				[module_name.to_snake_case(), type_def.get("name", "").to_snake_case()]
			var output_file_path: String = "res://%s/%s/%s/%s" % [PLUGIN_DATA_FOLDER, CODEGEN_FOLDER, folder_path, output_file_name]
			if not DirAccess.dir_exists_absolute("res://%s/%s/%s" % [PLUGIN_DATA_FOLDER, CODEGEN_FOLDER, folder_path]):
				DirAccess.make_dir_recursive_absolute("res://%s/%s/%s" % [PLUGIN_DATA_FOLDER, CODEGEN_FOLDER, folder_path])
			var file = FileAccess.open(output_file_path, FileAccess.WRITE)
			if file:
				file.store_string(content)
				file.close() 
			generated_files.append(output_file_path)
		elif type_def.has("enum"):
			if not type_def.get("is_sum_type"): continue
			var folder_path: String = "spacetime_types"
			var content: String = generate_enum_gdscript(type_def, module_name)
			var output_file_name: String = "%s_%s.gd" % \
				[module_name.to_snake_case(), type_def.get("name", "").to_snake_case()]
			var output_file_path: String = "res://%s/%s/%s/%s" % [PLUGIN_DATA_FOLDER ,CODEGEN_FOLDER, folder_path, output_file_name]
			if not DirAccess.dir_exists_absolute("res://%s/%s/%s" % [PLUGIN_DATA_FOLDER ,CODEGEN_FOLDER, folder_path]):
				DirAccess.make_dir_recursive_absolute("res://%s/%s/%s" % [PLUGIN_DATA_FOLDER, CODEGEN_FOLDER, folder_path])
			var file = FileAccess.open(output_file_path, FileAccess.WRITE)
			if file:
				file.store_string(content)
				file.close()
			generated_files.append(output_file_path)

	var module_content: String = generate_module_gdscript(schema)
	var output_file_name_module: String = "module_%s.gd" % module_name.to_snake_case() 
	var output_file_path_module: String = "res://%s/%s/%s" % [PLUGIN_DATA_FOLDER, CODEGEN_FOLDER, output_file_name_module] 
	var file_module = FileAccess.open(output_file_path_module, FileAccess.WRITE)
	if file_module:
		file_module.store_string(module_content)
		file_module.close()
		generated_files.append(output_file_path_module)

	var reducers_content: String = generate_reducer_gdscript(schema)
	var output_file_name_reducers: String = "module_%s_reducers.gd" % module_name.to_snake_case()
	var output_file_path_reducers: String = "res://%s/%s/%s" % [PLUGIN_DATA_FOLDER, CODEGEN_FOLDER, output_file_name_reducers]
	var file_reducers = FileAccess.open(output_file_path_reducers, FileAccess.WRITE)
	if file_reducers:
		file_reducers.store_string(reducers_content)
		file_reducers.close()
		generated_files.append(output_file_path_reducers)

	var types_content: String = generate_types_gdscript(schema)
	var output_file_name_types: String = "module_%s_types.gd" % module_name.to_snake_case()
	var output_file_path_types: String = "res://%s/%s/%s" % [PLUGIN_DATA_FOLDER ,CODEGEN_FOLDER, output_file_name_types]
	var file_types = FileAccess.open(output_file_path_types, FileAccess.WRITE)
	if file_types:
		file_types.store_string(types_content)
		file_types.close()
		generated_files.append(output_file_path_types)
		
	Spacetime.print_log(["Generated files:\n", "\n".join(generated_files)])
	return generated_files

func generate_struct_gdscript(type_def, module_name, table_names) -> String:
	var struct_name: String = type_def.get("name", "")
	var fields: Array = type_def.get("struct", [])
	var meta_data: Array = []
	var table_name: String = type_def.get("table_name", "")
	var _class_name: String = module_name.to_pascal_case() + struct_name.to_pascal_case()
	var _extends_class = "Resource"
	if table_name:
		_extends_class = "_ModuleTable"
		var primary_key_name: String = type_def.get("primary_key_name", "")
		if primary_key_name:
			meta_data.append("set_meta('primary_key', '%s')" % primary_key_name)
	
	var content: String = "#Do not edit this file, it is generated automatically.\n" + \
	"class_name %s extends %s\n\n" % [_class_name, _extends_class]
		
	if table_names.size() > 0:
		content += "const table_names: Array[String] = ["
		for i in range(table_names.size()):
			if i < table_names.size() - 1:
				content += "'%s'," % table_names[i]
			else:
				content += "'%s']\n\n" % table_names[i]
		
	var class_fields: Array = []
	for field in fields:
		var field_name: String = field.get("name", "")
		var original_inner_type_name: String = field.get("type", "Variant") 
		var gd_field_type: String
		var bsatn_meta_type_string: String

		if field.has("is_option"):
			gd_field_type = OPTION_CLASS_NAME
			if field.has("is_array_inside_option"):
				bsatn_meta_type_string = "vec_%s" % META_TYPE_MAP.get(original_inner_type_name, "Variant")
			else:
				bsatn_meta_type_string = META_TYPE_MAP.get(original_inner_type_name, original_inner_type_name)
		elif field.has("is_array"):
			var element_gd_type = TYPE_MAP.get(original_inner_type_name, "Variant")
			if field.has("is_option_inside_array"):
				element_gd_type = OPTION_CLASS_NAME
			gd_field_type = "Array[%s]" % element_gd_type
			var inner_meta = META_TYPE_MAP.get(original_inner_type_name, original_inner_type_name)
			bsatn_meta_type_string = "%s" % inner_meta
		else:
			gd_field_type = TYPE_MAP.get(original_inner_type_name, "Variant")
			bsatn_meta_type_string = META_TYPE_MAP.get(original_inner_type_name, original_inner_type_name)

		var add_meta_for_field = false
		if field.has("is_option") or field.has("is_array"):
			add_meta_for_field = true
		elif not GDNATIVE_TYPES.has(original_inner_type_name):
			add_meta_for_field = true
		elif META_TYPE_MAP.has(original_inner_type_name):
			add_meta_for_field = true
		
		if add_meta_for_field and not bsatn_meta_type_string.is_empty():
			meta_data.append("set_meta('bsatn_type_%s', &'%s')" % [field_name, bsatn_meta_type_string])
		
		content += "@export var %s: %s\n" % [field_name, gd_field_type]
		class_fields.append([field_name, gd_field_type])

	content += "\nfunc _init():\n"
	var has_content_in_init = false
	for m in meta_data:
		content += "\t%s\n" % m
		has_content_in_init = true
	
	if not has_content_in_init: 
		content += "\tpass\n"

	content += "\nstatic func create(%s) -> %s:\n" % \
	[", ".join(class_fields.map(func(x): return "_%s: %s" % [x[0], x[1]])), _class_name] + \
	"\tvar result = %s.new()\n" % [_class_name]
	for field_data in class_fields:
		var f_name: String = field_data[0] 
		content += "\tresult.%s = _%s\n" % [f_name, f_name]
	content += "\treturn result\n"
	return content

func generate_enum_gdscript(type_def, module_name) -> String:
	var enum_name: String = type_def.get("name", "")
	var variants: Array = type_def.get("enum", [""])
	var variant_names: String = ""
	for v_schema in variants:
		variant_names += "\t%s,\n" % [v_schema.get("name", "")]
	if not variant_names.is_empty():
		variant_names = variant_names.left(-2)
		
	var _class_name: String = module_name.to_pascal_case() + enum_name.to_pascal_case()
	var content: String = "#Do not edit this file, it is generated automatically.\n" + \
	"class_name %s extends RustEnum\n\n" % _class_name + \
	"enum {\n%s\n}\n\n" % variant_names + \
	"func _init():\n" + \
	"\tset_meta('enum_options', [%s])\n" % \
	[", ".join(variants.map(func(x): 
		var rust_type = META_TYPE_MAP.get(x.get("type", ""), x.get("type", "")) 
		return "&'%s'" % rust_type if not rust_type.is_empty() else "&''"
		))] + \
	"\tset_meta('bsatn_enum_type', &'%s')\n" % _class_name + \
	"\n" + \
	"static func parse_enum_name(i: int) -> String:\n" + \
	"\tmatch i:\n"
	for i in range(variants.size()):
		content += "\t\t%d: return &'%s'\n" % [i, variants[i].get("name", "")]
	content += "\t\t_:\n" + \
	"\t\t\tprinterr(\"Enum does not have value for %d. This is out of bounds.\" % i)\n" + \
	"\t\t\treturn &'Unknown'\n\n"
	for v_schema in variants:
		var variant_name: String = v_schema.get("name", "")
		var variant_gd_type: String = TYPE_MAP.get(v_schema.get("type", ""), "Variant")
		if v_schema.has("is_array"):
			variant_gd_type = "Array[%s]" % variant_gd_type
		
		content += "func get_%s() -> %s:\n" % [variant_name.to_snake_case(), variant_gd_type] + \
		"\treturn data\n\n"
		
	content +="static func create(type: int, _data: Variant = null) -> %s:\n" % _class_name + \
	"\tvar result = %s.new()\n" % _class_name + \
	"\tresult.value = type\n" + \
	"\tresult.data = _data\n" + \
	"\treturn result\n\n"
	for v_schema in variants:
		var variant_name: String = v_schema.get("name", "")
		var variant_gd_type: String = TYPE_MAP.get(v_schema.get("type", ""), "") 
		
		if not v_schema.has("type"):
			content += "static func create_%s() -> %s:\n" % [variant_name.to_snake_case(), _class_name] + \
			"\treturn create(%s)\n\n" % [variant_name]
			continue
		
		if variant_gd_type.is_empty() and v_schema.has("type"): 
			variant_gd_type = "Variant"

		if v_schema.has("is_array"):
			variant_gd_type = "Array[%s]" % variant_gd_type
		
		content += "static func create_%s(_data: %s) -> %s:\n" % [variant_name.to_snake_case(), variant_gd_type, _class_name] + \
		"\treturn create(%s, _data)\n\n" % [variant_name]
		
	return content.left(-2) if content.ends_with("\n\n") else content.left(-1) if content.ends_with("\n") else content

func generate_module_gdscript(schema: Dictionary) -> String:
	var module_name: String = schema.get("module", null)
	var content: String = "#Do not edit this file, it is generated automatically.\n" + \
	"class_name %sModule extends Resource\n\n" % module_name.to_pascal_case()
	content += "const Reducers = preload('res://%s/%s/module_%s_reducers.gd')\n" % [PLUGIN_DATA_FOLDER, CODEGEN_FOLDER, 
		module_name.to_snake_case()]
	content += "const Types = preload('res://%s/%s/module_%s_types.gd')\n\n" % [PLUGIN_DATA_FOLDER ,CODEGEN_FOLDER, 
		module_name.to_snake_case()]
	
	var types_part = generate_types_gdscript(schema, true)
	if not types_part.is_empty():
		content += types_part + "\n"
		
	content += generate_reducer_gdscript(schema) 
	return content

func generate_types_gdscript(schema: Dictionary, const_pointer: bool = false) -> String:
	var content: String = "" 
	var module_name: String = schema.get("module", null)
	for _type_def in schema.get("types", []):
		if _type_def.has("gd_native"): continue
		var type_name: String = _type_def.get("name", "")
		var subfolder = "spacetime_types"
		if _type_def.has("table_name"): 
			if not _type_def.has("primary_key_name"):
				continue
			if HIDE_PRIVATE_TABLES and not _type_def.get("is_public", []).has(true): continue
			subfolder = "tables"
		
		if const_pointer:
			content += "const %s = Types.%s\n" % \
			[type_name.to_pascal_case(), type_name.to_pascal_case()]
		else: 
			if _type_def.has("is_sum_type") and not _type_def.get("is_sum_type"): 
				content += "enum %s {\n" % type_name.to_pascal_case()
				var variants_str = ""
				for variant in _type_def.get("enum", []):
					var variant_name: String = variant.get("name", "")
					variants_str += "\t%s,\n" % variant_name.to_pascal_case() 
				if not variants_str.is_empty():
					variants_str = variants_str.left(-2)
				content += variants_str
				content += "\n}\n"
			else: 
				content += "const %s = preload('res://%s/%s/%s/%s_%s.gd')\n" % \
				[type_name.to_pascal_case(), PLUGIN_DATA_FOLDER, CODEGEN_FOLDER, subfolder, 
				module_name.to_snake_case(), type_name.to_snake_case()]
	return content

func generate_reducer_gdscript(schema: Dictionary) -> String:
	var content: String = "" 
	for reducer in schema.get("reducers", []):
		if reducer.get("is_scheduled", false) and HIDE_SCHEDULED_REDUCERS: continue
		var params_str_parts: Array[String] = []
		for param in reducer.get("params", []):
			var param_name: String = param.get("name", "")
			var gd_param_type: String
			var original_inner_type_name: String = param.get("type", "Variant")

			if param.has("is_option"):
				gd_param_type = OPTION_CLASS_NAME
			elif param.has("is_array"):
				var element_gd_type = TYPE_MAP.get(original_inner_type_name, "Variant")
				if param.has("is_option_inside_array"):
					element_gd_type = OPTION_CLASS_NAME
				gd_param_type = "Array[%s]" % element_gd_type
			else:
				gd_param_type = TYPE_MAP.get(original_inner_type_name, "Variant")
			params_str_parts.append("%s: %s" % [param_name, gd_param_type])
		
		var params_str : String
		if params_str_parts.is_empty():
			params_str = "cb: Callable = func(_t: TransactionUpdateData): pass"
		else:
			params_str = ", ".join(params_str_parts) + ", cb: Callable = func(_t: TransactionUpdateData): pass"

		var param_names_list = reducer.get("params", []).map(func(x): return x.get("name", ""))
		var param_names_str = ""
		if not param_names_list.is_empty():
			param_names_str = ", ".join(param_names_list)
		
		var param_bsatn_types_list = reducer.get("params", []).map(func(x): 
			var original_inner_type_name_bsatn: String = x.get("type", "Variant")
			var bsatn_param_type: String

			if x.has("is_option"):
				var inner_meta_for_option: String
				if x.has("is_array_inside_option"):
					inner_meta_for_option = "vec_%s" % META_TYPE_MAP.get(original_inner_type_name_bsatn, original_inner_type_name_bsatn)
				else:
					inner_meta_for_option = META_TYPE_MAP.get(original_inner_type_name_bsatn, original_inner_type_name_bsatn)
				bsatn_param_type = "%s" % inner_meta_for_option
			else:
				bsatn_param_type = META_TYPE_MAP.get(original_inner_type_name_bsatn, original_inner_type_name_bsatn)
			
			if bsatn_param_type.is_empty(): return "''" 
			return "&'%s'" % bsatn_param_type
			)
		var param_bsatn_types_str = ""
		if not param_bsatn_types_list.is_empty():
			param_bsatn_types_str = ", ".join(param_bsatn_types_list)
			
		var reducer_name: String = reducer.get("name", "")
		content += "static func %s(%s) -> void:\n" % [reducer_name, params_str] + \
		"\tvar __id__: int = SpacetimeDB.call_reducer('%s', [%s], [%s])\n" % \
		[reducer_name, param_names_str, param_bsatn_types_str] + \
		"\tvar __result__ = await SpacetimeDB.wait_for_reducer_response(__id__)\n" + \
		"\tcb.call(__result__)\n\n"
	
	if not content.is_empty():
		content = content.left(-2) 
	return content

func generate_module_link(modules: Array[String]) -> void:
	var content: String = "#Do not edit this file, it is generated automatically.\n" + \
	"class_name SpacetimeModule extends Resource\n\n"
	for module_name in modules:
		content += "const %s = preload('res://%s/%s/module_%s.gd')\n" % \
		[module_name.to_pascal_case(), PLUGIN_DATA_FOLDER, CODEGEN_FOLDER, module_name.to_snake_case()]
	var output_file_name: String = "spacetime_modules.gd"
	var output_file_path: String = "res://%s/%s/%s" % [PLUGIN_DATA_FOLDER ,CODEGEN_FOLDER, output_file_name]
	var file = FileAccess.open(output_file_path, FileAccess.WRITE)
	if file:
		file.store_string(content)
		file.close()

func parse_schema(schema: Dictionary, module_name: String) -> Dictionary:
	var schema_tables: Array = schema.get("tables", [])
	var schema_types_raw: Array = schema.get("types", []) 
	var schema_reducers: Array = schema.get("reducers", [])
	var typespace: Array = schema.get("typespace", {}).get("types", [])
	schema_types_raw.sort_custom(func(a, b): return a.get("ty", -1) < b.get("ty", -1))
	var parsed_types_list := [] 
	var scheduled_reducers: Array[String] = []
	
	var process_elements_func = func(elements_arr: Array, element_key_in_schema: String) -> Array:
		var parsed_elements_result := []
		for e_schema in elements_arr:
			var element_data := { "name": e_schema.get("name",{}).get("some", null) }
			var algebraic_type_desc = e_schema.get(element_key_in_schema, {}) 
			var original_inner_type_name: String = "Variant"
			if algebraic_type_desc.has("Sum") and is_sum_option(algebraic_type_desc.Sum):
				element_data["is_option"] = true
				var some_variant_type = {}
				for v_opt in algebraic_type_desc.Sum.variants:
					if v_opt.get("name",{}).get("some") == "some":
						some_variant_type = v_opt.get('algebraic_type', {})
						break
				if some_variant_type.is_empty() and not algebraic_type_desc.Sum.variants.is_empty(): # Fallback if not found, or if "some" is truly empty
					printerr("Could not find 'some' variant for Option type, or 'some' variant type is empty: ", algebraic_type_desc)
					
				if some_variant_type.has("Array"):
					element_data["is_array_inside_option"] = true
					var array_content_type = some_variant_type.Array
					if array_content_type.has("Ref"):
						var ref_idx = int(array_content_type.Ref)
						if ref_idx >= schema_types_raw.size(): printerr("Ref index out of bounds in Option<Array<Ref>>"); return [] 
						original_inner_type_name = schema_types_raw[ref_idx].get("name", {}).get("name", null)
					elif array_content_type.is_empty(): # e.g. Option<Array<()>>
						original_inner_type_name = "Nil" 
					else:
						if array_content_type.keys().is_empty(): printerr("Empty type for Option<Array<T>> inner T"); return []
						original_inner_type_name = array_content_type.keys()[0]
				elif some_variant_type.has("Ref"):
					var ref_idx = int(some_variant_type.Ref)
					if ref_idx >= schema_types_raw.size(): printerr("Ref index out of bounds in Option<Ref>"); return []
					original_inner_type_name = schema_types_raw[ref_idx].get("name", {}).get("name", null)
				elif some_variant_type.has("Product") and \
					 some_variant_type.Product.get("elements", []).is_empty(): # Option<()>
					original_inner_type_name = "Nil"
				elif some_variant_type.is_empty(): # Also Option<()> if algebraic_type for "some" is {}
					original_inner_type_name = "Nil"
				else:
					if some_variant_type.keys().is_empty(): printerr("Empty type for Option 'some' variant's T"); return []
					original_inner_type_name = some_variant_type.keys()[0]
			elif algebraic_type_desc.has("Array"):
				element_data["is_array"] = true
				var array_content_type = algebraic_type_desc.Array
				if array_content_type.has("Ref"):
					var ref_idx = int(array_content_type.Ref)
					if ref_idx >= schema_types_raw.size(): printerr("Ref index out of bounds in Array<Ref>"); return []
					original_inner_type_name = schema_types_raw[ref_idx].get("name", {}).get("name", null)
				elif array_content_type.has("Sum") and is_sum_option(array_content_type.Sum):				
					element_data["is_option_inside_array"] = true
					var some_variant_type = {}
					for v_opt in array_content_type.Sum.variants:
						if v_opt.get("name",{}).get("some") == "some":
							some_variant_type = v_opt.get('algebraic_type', {})
							break
					if some_variant_type.is_empty() and not array_content_type.Sum.variants.is_empty(): # Fallback if not found, or if "some" is truly empty
						printerr("Could not find 'some' variant for Array<Option> type, or 'some' variant type is empty: ", array_content_type)
					if some_variant_type.has("Ref"):
						var ref_idx = int(some_variant_type.Ref)
						if ref_idx >= schema_types_raw.size(): printerr("Ref index out of bounds in Array<Option<Ref>>"); return []
						original_inner_type_name = schema_types_raw[ref_idx].get("name", {}).get("name", null)
					else:
						if some_variant_type.keys().is_empty(): printerr("Empty type for Array<Option<T>> inner T"); return []
						original_inner_type_name = some_variant_type.keys()[0]
				elif array_content_type.is_empty(): # Array<()>
					original_inner_type_name = "Nil"
				else:
					if array_content_type.keys().is_empty(): printerr("Empty type for Array element T"); return []
					original_inner_type_name = array_content_type.keys()[0]
			elif algebraic_type_desc.has("Ref"):
				var ref_idx = int(algebraic_type_desc.Ref)
				if ref_idx >= schema_types_raw.size(): printerr("Ref index out of bounds for Ref type"); return []
				original_inner_type_name = schema_types_raw[ref_idx].get("name", {}).get("name", null)
			elif algebraic_type_desc.has("Product") and \
				 algebraic_type_desc.Product.get("elements", []).size() == 1 and \
				 algebraic_type_desc.Product.elements[0].get('name', {}).get('some', "").begins_with("__"): # Special types like __identity__
				original_inner_type_name = algebraic_type_desc.Product.elements[0].get('name', {}).get('some', null)
			elif algebraic_type_desc.has("Product") and algebraic_type_desc.Product.get("elements", []).is_empty(): # Unit type ()
				original_inner_type_name = "Nil"
			elif algebraic_type_desc.is_empty(): # Also Unit type ()
				original_inner_type_name = "Nil"
			else: 
				if algebraic_type_desc.keys().is_empty():
					printerr("Empty algebraic_type_desc for element: ", e_schema); return []
				original_inner_type_name = algebraic_type_desc.keys()[0]
			
			if original_inner_type_name == null:
				printerr("Failed to determine type name for element: ", e_schema); return []
			element_data["type"] = original_inner_type_name
			parsed_elements_result.append(element_data)
		return parsed_elements_result

	for type_info in schema_types_raw:
		var type_name: String = type_info.get("name", {}).get("name", null)
		if not type_name:
			printerr("Invalid schema: Type name not found for type: %s" % type_info)
			return {}
		var type_data := {
			"name": type_name,
		}
		if GDNATIVE_TYPES.has(type_name):
			type_data["gd_native"] = true
		
		var ty_idx := int(type_info.get("ty", -1)) 
		if ty_idx == -1:
			printerr("Invalid schema: Type 'ty' not found for type: %s" % type_info)
			return {}
		if ty_idx >= typespace.size():
			printerr("Invalid schema: Type index %d out of bounds for typespace (size %d) for type %s" % [ty_idx, typespace.size(), type_name])
			return {}

		var current_type_definition = typespace[ty_idx]
		var struct_def: Dictionary = current_type_definition.get("Product", {}) 
		var sum_type_def: Dictionary = current_type_definition.get("Sum", {}) 

		if struct_def:
			var struct_elements = process_elements_func.call(struct_def.get("elements", []), "algebraic_type")
			if struct_elements.is_empty() and not struct_def.get("elements", []).is_empty() and not (struct_def.get("elements",[]).size() == 1 and struct_def.elements[0].get("algebraic_type",{}).is_empty()):
				var is_truly_unit_struct = true
				if not struct_def.get("elements", []).is_empty():
					for el_check in struct_def.get("elements", []):
						if not el_check.get("algebraic_type", {}).is_empty() and not (el_check.get("algebraic_type", {}).has("Product") and el_check.get("algebraic_type", {}).Product.get("elements",[]).is_empty()):
							is_truly_unit_struct = false
							break
				if not is_truly_unit_struct:
					printerr("Error processing struct elements for: ", type_name)
					return {}
			
			if not type_data.has("gd_native"):
				TYPE_MAP[type_name] = module_name.to_pascal_case() + type_name.to_pascal_case()
				META_TYPE_MAP[type_name] = module_name.to_pascal_case() + type_name.to_pascal_case()
			type_data["struct"] = struct_elements
			parsed_types_list.append(type_data)
		elif sum_type_def: 
			var parsed_variants := []
			type_data["is_sum_type"] = false
			for v_schema in sum_type_def.get("variants", []):
				var variant_data := { "name": v_schema.get("name",{}).get("some", null) }
				var variant_algebraic_type = v_schema.get("algebraic_type", {})
				var variant_inner_type_name: String = ""
				
				if not variant_algebraic_type.is_empty() and \
				   not (variant_algebraic_type.has("Product") and variant_algebraic_type.Product.get("elements", []).is_empty()):
					type_data["is_sum_type"] = true
					if variant_algebraic_type.has("Array"):
						variant_data["is_array"] = true
						var array_content = variant_algebraic_type.Array
						if array_content.has("Ref"):
							var ref_idx = int(array_content.Ref)
							if ref_idx >= schema_types_raw.size(): printerr("Ref index out of bounds for Sum variant Array<Ref>"); return {}
							variant_inner_type_name = schema_types_raw[ref_idx].get("name",{}).get("name",null)
						elif array_content.keys().is_empty(): variant_inner_type_name = "Nil"
						else: variant_inner_type_name = array_content.keys()[0]
					elif variant_algebraic_type.has("Ref"):
						var ref_idx = int(variant_algebraic_type.Ref)
						if ref_idx >= schema_types_raw.size(): printerr("Ref index out of bounds for Sum variant Ref"); return {}
						variant_inner_type_name = schema_types_raw[ref_idx].get("name",{}).get("name",null)
					else: 
						if variant_algebraic_type.keys().is_empty(): printerr("Empty type for Sum variant data"); return {}
						variant_inner_type_name = variant_algebraic_type.keys()[0]
					
					if variant_inner_type_name == null: printerr("Null type name for Sum variant data"); return {}
					variant_data["type"] = variant_inner_type_name
				parsed_variants.append(variant_data)
			
			type_data["enum"] = parsed_variants
			parsed_types_list.append(type_data)

			if not type_data.get("is_sum_type"): 
				META_TYPE_MAP[type_name] = "u8" 
				TYPE_MAP[type_name] = "{0}Module.{1}".format([module_name.to_pascal_case(), type_name.to_pascal_case()])
			else: 
				TYPE_MAP[type_name] = module_name.to_pascal_case() + type_name.to_pascal_case()
				META_TYPE_MAP[type_name] = module_name.to_pascal_case() + type_name.to_pascal_case()
		else:
			if not type_data.has("gd_native"):
				if TYPE_MAP.has(type_name) and not GDNATIVE_TYPES.has(type_name):
					type_data["struct"] = [] 
					parsed_types_list.append(type_data)
				else:
					Spacetime.print_log("Type '%s' has no Product/Sum definition in typespace and is not GDNative. Skipping." % type_name)


	for table_info in schema_tables:
		var table_name_str: String = table_info.get("name", null) 
		var ref_idx_raw = table_info.get("product_type_ref", null) 
		if ref_idx_raw == null or table_name_str == null: continue
		var ref_idx = int(ref_idx_raw)
		
		var target_type_def = null
		var original_type_name_for_table = "UNKNOWN_TYPE_FOR_TABLE"
		if ref_idx < schema_types_raw.size():
			original_type_name_for_table = schema_types_raw[ref_idx].get("name", {}).get("name")
			for pt in parsed_types_list:
				if pt.name == original_type_name_for_table:
					target_type_def = pt
					break
		
		if target_type_def == null or not target_type_def.has("struct"):
			printerr("Table '%s' refers to an invalid or non-struct type (index %s in original schema, name %s)." % [table_name_str, str(ref_idx), original_type_name_for_table if original_type_name_for_table else "N/A"])
			continue

		if not target_type_def.has("table_names"):
			target_type_def.table_names = []
		target_type_def.table_names.append(table_name_str)
		target_type_def.table_name = table_name_str 
		var primary_key_indices: Array = table_info.get("primary_key", [])
		if primary_key_indices.size() == 1:
			var pk_field_idx = int(primary_key_indices[0])
			if pk_field_idx < target_type_def.struct.size():
				target_type_def.primary_key = pk_field_idx
				target_type_def.primary_key_name = target_type_def.struct[pk_field_idx].name
			else:
				printerr("Primary key index %d out of bounds for table %s (struct size %d)" % [pk_field_idx, table_name_str, target_type_def.struct.size()])
		if not target_type_def.has("is_public"): target_type_def.is_public = []
		if table_info.get("table_access", {}).has("Private"):
			target_type_def.is_public.append(false)
		else: target_type_def.is_public.append(true)
		if table_info.get("schedule", {}).has("some"):
			var schedule = table_info.get("schedule", {}).some
			target_type_def.schedule = schedule
			scheduled_reducers.append(schedule.reducer_name)
	
	var parsed_reducers_list := [] 
	for reducer_info in schema_reducers:
		var lifecycle = reducer_info.get("lifecycle", {}).get("some", null)
		if lifecycle: continue 
		var r_name = reducer_info.get("name", null) 
		if r_name == null:
			printerr("Reducer found with no name: ", reducer_info)
			continue
		var reducer_data: Dictionary = {"name": r_name}
		
		var reducer_raw_params = reducer_info.get("params", {}).get("elements", [])
		var reducer_params = process_elements_func.call(reducer_raw_params, "algebraic_type")
		
		if reducer_params.is_empty() and not reducer_raw_params.is_empty():
			var all_params_were_unit = true
			for raw_param in reducer_raw_params:
				var alg_type = raw_param.get("algebraic_type", {})
				if not alg_type.is_empty() and not (alg_type.has("Product") and alg_type.Product.get("elements",[]).is_empty()):
					all_params_were_unit = false
					break
			if not all_params_were_unit:
				printerr("Error processing reducer params for: ", r_name)
				return {}
		
		reducer_data["params"] = reducer_params
		
		if r_name in scheduled_reducers:
			reducer_data["is_scheduled"] = true
		parsed_reducers_list.append(reducer_data)

	var parsed_schema_output = { 
		"module": module_name.to_pascal_case(),
		"types": parsed_types_list,
		"reducers": parsed_reducers_list,
		"type_map": TYPE_MAP, 
		"meta_type_map": META_TYPE_MAP,
		"tables": schema_tables, 
	}
	return parsed_schema_output


func is_sum_option(sum_def) -> bool: 
	var variants = sum_def.get("variants", [])
	if variants.size() != 2:
		return false
	
	var name1 = variants[0].get("name", {}).get("some", "")
	var name2 = variants[1].get("name", {}).get("some", "")

	var found_some = false
	var found_none = false
	var none_is_unit = false

	for v_idx in range(variants.size()):
		var v_name = variants[v_idx].get("name", {}).get("some", "")
		if v_name == "some":
			found_some = true
		elif v_name == "none":
			found_none = true
			var none_variant_type = variants[v_idx].get("algebraic_type", {})
			if none_variant_type.has("Product") and none_variant_type.Product.get("elements", []).is_empty():
				none_is_unit = true
			elif none_variant_type.is_empty():
				none_is_unit = true


	return found_some and found_none and none_is_unit

# Reserving the following for future use
# We will want to make the parasing more recursive to handle the nested types with less if statements
func parse_field_type(field_type: Dictionary, data: Dictionary, schema_types: Array) -> String:
	if field_type.has("Array"):
		var nested_type = data.get("nested_type", [])
		nested_type.append(&"Array")
		data["nested_type"] = nested_type
		data["is_array"] = true		
		field_type = field_type.Array
		return parse_field_type(field_type, data, schema_types)
	elif field_type.has("Product"):
		return field_type.Product.get("elements", [])[0].get('name', {}).get('some', null)
	elif field_type.has("Sum"):
		if is_sum_option(field_type.Sum):
			var nested_type = data.get("nested_type", [])
			nested_type.append(&"Option")
			data["nested_type"] = nested_type
			data["is_option"] = true			
		field_type = field_type.Sum.variants[0].get('algebraic_type', {})
		return parse_field_type(field_type, data, schema_types)
	elif field_type.has("Ref"):
		return schema_types[field_type.Ref].get("name", {}).get("name", null)
	else:
		return field_type.keys()[0]

func parse_variant_type(variant_type: Dictionary, data: Dictionary, schema_types: Array) -> String:
	if variant_type.has("Array"):
		var nested_type = data.get("nested_type", [])
		nested_type.append(&"Array")
		data["nested_type"] = nested_type
		data["is_array"] = true
		variant_type = variant_type.Array
		return parse_variant_type(variant_type, data, schema_types)
	elif variant_type.has("Product"):
		var variant_type_array = variant_type.Product.get("elements", [])
		if variant_type_array.size() >= 1:
			return variant_type_array[0].get('name', {}).get('some', null)
		else:
			return ""
	elif variant_type.has("Sum"):
		if is_sum_option(variant_type.Sum):
			var nested_type = data.get("nested_type", [])
			nested_type.append(&"Option")
			data["nested_type"] = nested_type
			data["is_option"] = true
		variant_type = variant_type.Sum.variants[0].get('algebraic_type', {})
		return parse_variant_type(variant_type, data, schema_types)
	elif variant_type.has("Ref"):
		return schema_types[variant_type.Ref].get("name", {}).get("name", null)
	else:
		return variant_type.keys()[0]