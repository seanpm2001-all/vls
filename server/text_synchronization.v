module server

import json
import lsp
import os
import analyzer

fn (mut ls Vls) analyze_file(file File) {
	ls.store.clear_messages()
	file_path := file.uri.path()
	ls.store.set_active_file_path(file_path, file.version)
	ls.store.import_modules_from_tree(file.tree, file.source, os.join_path(file.uri.dir_path(),
		'modules'), ls.root_uri.path(), os.dir(os.dir(file_path)))

	ls.store.register_symbols_from_tree(file.tree, file.source, false)
	ls.store.cleanup_imports()
	if Feature.analyzer_diagnostics in ls.enabled_features {
		ls.store.analyze(file.tree, file.source)
	}
}

fn (mut ls Vls) did_open(_ string, params string) {
	did_open_params := json.decode(lsp.DidOpenTextDocumentParams, params) or {
		ls.panic(err.msg)
		return
	}

	ls.parser.reset()
	src := did_open_params.text_document.text
	uri := did_open_params.text_document.uri
	project_dir := uri.dir_path()
	mut should_scan_whole_dir := false

	// should_scan_whole_dir is toggled if
	// - it's V file ending with .v format
	// - the project directory does not end with a dot (.)
	// - and has not been present in the dependency tree
	if uri.ends_with('.v') && project_dir != '.' && !ls.store.dependency_tree.has(project_dir) {
		should_scan_whole_dir = true
	}

	mut files_to_analyze := if should_scan_whole_dir { os.ls(project_dir) or {
			[
				uri.path(),
			]} } else { [
			uri.path(),
		] }

	for file_name in files_to_analyze {
		if should_scan_whole_dir && !analyzer.should_analyze_file(file_name) {
			continue
		}

		file_uri := lsp.document_uri_from_path(if file_name.starts_with(project_dir) {
			file_name
		} else {
			os.join_path(project_dir, file_name)
		})

		mut has_file := file_uri in ls.files
		mut should_be_analyzed := has_file

		// Create file only if source does not exist
		if !has_file {
			source := if file_uri != uri { os.read_bytes(file_name) or { [] } } else { src.bytes() }

			ls.files[file_uri] = File{
				uri: file_uri
				source: source
				tree: ls.parser.parse_bytes(source)
				version: 1
			}

			has_file = true
		}

		// If data about the document/file has recently been created,
		// mark it as "should_be_analyzed" (hence the variable name).
		if !should_be_analyzed && has_file {
			should_be_analyzed = true
		}

		// Analyze only if both source and tree exists
		if should_be_analyzed {
			ls.analyze_file(ls.files[file_uri])
			ls.show_diagnostics(file_uri)
		}

		// ls.log_message('$file_uri | has_file: $has_file | should_be_analyzed: $should_be_analyzed',
		// 	.info)
	}

	ls.store.set_active_file_path(uri.path(), ls.files[uri].version)
	if v_check_results := ls.exec_v_diagnostics(uri) {
		ls.publish_diagnostics(uri, v_check_results)
	}
}

fn (mut ls Vls) did_change(_ string, params string) {
	did_change_params := json.decode(lsp.DidChangeTextDocumentParams, params) or {
		ls.panic(err.msg)
		return
	}

	uri := did_change_params.text_document.uri
	if !ls.store.is_file_active(uri.path()) {
		ls.parser.reset()
	}

	ls.store.set_active_file_path(uri.path(), did_change_params.text_document.version)

	mut new_src := ls.files[uri].source
	ls.publish_diagnostics(uri, []lsp.Diagnostic{})

	for content_change in did_change_params.content_changes {
		start_idx := compute_offset(new_src, content_change.range.start.line, content_change.range.start.character)
		old_end_idx := compute_offset(new_src, content_change.range.end.line, content_change.range.end.character)
		new_end_idx := start_idx + content_change.text.len
		start_pos := content_change.range.start
		old_end_pos := content_change.range.end
		new_end_pos := compute_position(new_src, new_end_idx)

		old_len := new_src.len
		new_len := old_len - (old_end_idx - start_idx) + content_change.text.len
		diff := new_len - old_len
		right_text := new_src[old_end_idx..].clone()

		// remove immediately the symbol
		if content_change.text.len == 0 && diff < 0 {
			ls.store.delete_symbol_at_node(ls.files[uri].tree.root_node(), new_src,
				start_point: lsp_pos_to_tspoint(start_pos)
				end_point: lsp_pos_to_tspoint(old_end_pos)
				start_byte: u32(start_idx)
				end_byte: u32(old_end_idx)
			)
		}

		// the new source should grow or shrink
		unsafe { new_src.grow_len(diff) }

		// copy(new_src[new_end_idx ..], old_src[old_end_idx ..])
		mut new_idx := new_end_idx
		for right_idx := 0; new_idx < new_src.len && right_idx < right_text.len; right_idx++ {
			new_src[new_idx] = right_text[right_idx]
			new_idx++
		}

		// add the remaining characters to the remaining items
		mut insert_idx := start_idx
		for change_idx := 0; insert_idx < new_src.len && change_idx < content_change.text.len; change_idx++ {
			new_src[insert_idx] = content_change.text[change_idx]
			insert_idx++
		}

		// edit the tree
		ls.files[uri].tree.edit(
			start_byte: u32(start_idx)
			old_end_byte: u32(old_end_idx)
			new_end_byte: u32(new_end_idx)
			start_point: lsp_pos_to_tspoint(start_pos)
			old_end_point: lsp_pos_to_tspoint(old_end_pos)
			new_end_point: lsp_pos_to_tspoint(new_end_pos)
		)
	}

	mut new_tree := ls.parser.parse_bytes_with_old_tree(new_src, ls.files[uri].tree)
	// ls.log_message('${ls.files[uri].tree.get_changed_ranges(new_tree)}', .info)

	// ls.log_message('new tree: ${new_tree.root_node().sexpr_str()}', .info)
	ls.files[uri].tree = new_tree
	ls.files[uri].source = new_src
	ls.files[uri].version = did_change_params.text_document.version

	// $if !test {
	// 	ls.log_message(ls.store.imports.str(), .info)
	// 	ls.log_message(ls.store.dependency_tree.str(), .info)
	// }
}

[manualfree]
fn (mut ls Vls) did_close(_ string, params string) {
	did_close_params := json.decode(lsp.DidCloseTextDocumentParams, params) or {
		ls.panic(err.msg)
		return
	}

	uri := did_close_params.text_document.uri
	// unsafe {
	// 	ls.files[uri].free()
	// 	ls.store.opened_scopes[uri.path()].free()
	// }
	ls.files.delete(uri)
	ls.store.opened_scopes.delete(uri.path())

	if ls.files.count(uri.dir()) == 0 {
		ls.store.delete(uri.dir_path())
	}

	// NB: The diagnostics will be cleared if:
	// - TODO: If a workspace has opened multiple programs with main() function and one of them is closed.
	// - If a file opened is outside the root path or workspace.
	// - If there are no remaining files opened on a specific folder.
	if ls.files.len == 0 || !uri.starts_with(ls.root_uri) {
		ls.publish_diagnostics(uri, []lsp.Diagnostic{})
	}
}

fn (mut ls Vls) did_save(id string, params string) {
	did_save_params := json.decode(lsp.DidSaveTextDocumentParams, params) or {
		ls.panic(err.msg)
		return
	}
	uri := did_save_params.text_document.uri
	if v_check_results := ls.exec_v_diagnostics(uri) {
		ls.publish_diagnostics(uri, v_check_results)
	}
}
