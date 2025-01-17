let s:enabled = 0
let s:already_setup = 0
let s:servers = {} " { lsp_id, server_info, init_callbacks, init_result, buffers: { path: { changed_tick } }

let s:notification_callbacks = [] " { name, callback }

" This hold previous content for each language servers to make
" DidChangeTextDocumentParams. The key is buffer numbers:
"    {
"      1: {
"        "golsp": [ "first-line", "next-line", ... ],
"        "bingo": [ "first-line", "next-line", ... ]
"      },
"      2: {
"        "pyls": [ "first-line", "next-line", ... ]
"      }
"    }
let s:file_content = {}

" do nothing, place it here only to avoid the message
augroup _lsp_silent_
    autocmd!
    autocmd User lsp_setup silent
    autocmd User lsp_register_server silent
    autocmd User lsp_unregister_server silent
    autocmd User lsp_server_init silent
    autocmd User lsp_server_exit silent
    autocmd User lsp_complete_done silent
    autocmd User lsp_float_opened silent
    autocmd User lsp_float_closed silent
augroup END

function! lsp#log_verbose(...) abort
    if g:lsp_log_verbose
        call call(function('lsp#log'), a:000)
    endif
endfunction

function! lsp#log(...) abort
    if !empty(g:lsp_log_file)
        call writefile([strftime('%c') . ':' . json_encode(a:000)], g:lsp_log_file, 'a')
    endif
endfunction

function! lsp#enable() abort
    if s:enabled
        return
    endif
    if !s:already_setup
        doautocmd User lsp_setup
        let s:already_setup = 1
    endif
    let s:enabled = 1
    if g:lsp_diagnostics_enabled
        if g:lsp_signs_enabled | call lsp#ui#vim#signs#enable() | endif
        if g:lsp_virtual_text_enabled | call lsp#ui#vim#virtual#enable() | endif
        if g:lsp_highlights_enabled | call lsp#ui#vim#highlights#enable() | endif
        if g:lsp_textprop_enabled | call lsp#ui#vim#diagnostics#textprop#enable() | endif
    endif
    call s:register_events()
endfunction

function! lsp#disable() abort
    if !s:enabled
        return
    endif
    call lsp#ui#vim#signs#disable()
    call s:unregister_events()
    let s:enabled = 0
endfunction

function! lsp#get_server_names() abort
    return keys(s:servers)
endfunction

function! lsp#get_server_info(server_name) abort
    return s:servers[a:server_name]['server_info']
endfunction

function! lsp#get_server_capabilities(server_name) abort
    let l:server = s:servers[a:server_name]
    return has_key(l:server, 'init_result') ? l:server['init_result']['result']['capabilities'] : {}
endfunction

function! s:server_status(server_name) abort
    if !has_key(s:servers, a:server_name)
        return 'unknown server'
    endif
    let l:server = s:servers[a:server_name]
    if has_key(l:server, 'exited')
        return 'exited'
    endif
    if has_key(l:server, 'init_callbacks')
        return 'starting'
    endif
    if has_key(l:server, 'failed')
        return 'failed'
    endif
    if has_key(l:server, 'init_result')
        return 'running'
    endif
    return 'not running'
endfunction

" Returns the current status of all servers (if called with no arguments) or
" the given server (if given an argument). Can be one of "unknown server",
" "exited", "starting", "failed", "running", "not running"
function! lsp#get_server_status(...) abort
    if a:0 == 0
        let l:strs = map(keys(s:servers), {k, v -> v . ": " . s:server_status(v)})
        return join(l:strs, "\n")
    else
        return s:server_status(a:1)
    endif
endfunction

" @params {server_info} = {
"   'name': 'go-langserver',        " requried, must be unique
"   'whitelist': ['go'],            " optional, array of filetypes to whitelist, * for all filetypes
"   'blacklist': [],                " optional, array of filetypes to blacklist, * for all filetypes,
"   'cmd': {server_info->['go-langserver]} " function that takes server_info and returns array of cmd and args, return empty if you don't want to start the server
" }
function! lsp#register_server(server_info) abort
    let l:server_name = a:server_info['name']
    if has_key(s:servers, l:server_name)
        call lsp#log('lsp#register_server', 'server already registered', l:server_name)
    endif
    let s:servers[l:server_name] = {
        \ 'server_info': a:server_info,
        \ 'lsp_id': 0,
        \ 'buffers': {},
        \ }
    call lsp#log('lsp#register_server', 'server registered', l:server_name)
    doautocmd User lsp_register_server
endfunction

function! lsp#register_notifications(name, callback) abort
    call add(s:notification_callbacks, { 'name': a:name, 'callback': a:callback })
endfunction

function! lsp#unregister_notifications(name) abort
    " TODO
endfunction

function! lsp#stop_server(server_name) abort
    if has_key(s:servers, a:server_name) && s:servers[a:server_name]['lsp_id'] > 0
        call lsp#client#stop(s:servers[a:server_name]['lsp_id'])
    endif
endfunction

function! s:register_events() abort
    augroup lsp
        autocmd!
        autocmd BufReadPost * call s:on_text_document_did_open()
        autocmd BufWritePost * call s:on_text_document_did_save()
        autocmd BufWinLeave * call s:on_text_document_did_close()
        autocmd BufWipeout * call s:on_buf_wipeout(bufnr('<afile>'))
        autocmd InsertLeave * call s:on_text_document_did_change()
        autocmd TextChanged * call s:on_text_document_did_change()
        if exists('##TextChangedP')
            autocmd TextChangedP * call s:on_text_document_did_change()
        endif
        autocmd CursorMoved * call s:on_cursor_moved()
        autocmd BufWinEnter,BufWinLeave,InsertEnter * call lsp#ui#vim#references#clean_references()
        autocmd CursorMoved * if g:lsp_highlight_references_enabled | call lsp#ui#vim#references#highlight(v:false) | endif
    augroup END
    call s:on_text_document_did_open()
endfunction

function! s:unregister_events() abort
    augroup lsp
        autocmd!
    augroup END
    doautocmd User lsp_unregister_server
endfunction

function! s:on_text_document_did_open() abort
    let l:buf = bufnr('%')
    if getbufvar(l:buf, '&buftype') ==# 'terminal' | return | endif
    call lsp#log('s:on_text_document_did_open()', l:buf, &filetype, getcwd(), lsp#utils#get_buffer_uri(l:buf))
    for l:server_name in lsp#get_whitelisted_servers(l:buf)
        call s:ensure_flush(l:buf, l:server_name, function('s:Noop'))
    endfor
endfunction

function! s:on_text_document_did_save() abort
    let l:buf = bufnr('%')
    if getbufvar(l:buf, '&buftype') ==# 'terminal' | return | endif
    call lsp#log('s:on_text_document_did_save()', l:buf)
    for l:server_name in lsp#get_whitelisted_servers(l:buf)
        call s:ensure_flush(l:buf, l:server_name, {result->s:call_did_save(l:buf, l:server_name, result, function('s:Noop'))})
    endfor
endfunction

function! s:on_text_document_did_change() abort
    let l:buf = bufnr('%')
    if getbufvar(l:buf, '&buftype') ==# 'terminal' | return | endif
    call lsp#log('s:on_text_document_did_change()', l:buf)
    call s:add_didchange_queue(l:buf)
endfunction

function! s:on_cursor_moved() abort
    let l:buf = bufnr('%')
    if getbufvar(l:buf, '&buftype') ==# 'terminal' | return | endif
    call lsp#ui#vim#diagnostics#echo#cursor_moved()
endfunction

function! s:call_did_save(buf, server_name, result, cb) abort
    if lsp#client#is_error(a:result['response'])
        return
    endif

    let l:server = s:servers[a:server_name]
    let l:path = lsp#utils#get_buffer_uri(a:buf)

    let [l:supports_did_save, l:did_save_options] = lsp#capabilities#get_text_document_save_registration_options(a:server_name)
    if !l:supports_did_save
        let l:msg = s:new_rpc_success('---> ignoring textDocument/didSave. not supported by server', { 'server_name': a:server_name, 'path': l:path })
        call lsp#log(l:msg)
        call a:cb(l:msg)
        return
    endif

    call s:update_file_content(a:buf, a:server_name, lsp#utils#buffer#_get_lines(a:buf))

    let l:buffers = l:server['buffers']
    let l:buffer_info = l:buffers[l:path]

    let l:params = {
        \ 'textDocument': s:get_text_document_identifier(a:buf),
        \ }

    if l:did_save_options['includeText']
        let l:params['text'] = s:get_text_document_text(a:buf, a:server_name)
    endif
    call s:send_notification(a:server_name, {
        \ 'method': 'textDocument/didSave',
        \ 'params': l:params,
        \ })

    let l:msg = s:new_rpc_success('textDocument/didSave sent', { 'server_name': a:server_name, 'path': l:path })
    call lsp#log(l:msg)
    call a:cb(l:msg)
endfunction

function! s:on_text_document_did_close() abort
    let l:buf = bufnr('%')
    if getbufvar(l:buf, '&buftype') ==# 'terminal' | return | endif
    call lsp#log('s:on_text_document_did_close()', l:buf)
endfunction

function! s:get_last_file_content(buf, server_name) abort
    if has_key(s:file_content, a:buf) && has_key(s:file_content[a:buf], a:server_name)
        return s:file_content[a:buf][a:server_name]
    endif
    return []
endfunction

function! s:update_file_content(buf, server_name, new) abort
    if !has_key(s:file_content, a:buf)
        let s:file_content[a:buf] = {}
    endif
    call lsp#log('s:update_file_content()', a:buf)
    let s:file_content[a:buf][a:server_name] = a:new
endfunction

function! s:on_buf_wipeout(buf) abort
    if has_key(s:file_content, a:buf)
        call remove(s:file_content, a:buf)
    endif
endfunction

function! s:ensure_flush_all(buf, server_names) abort
    for l:server_name in a:server_names
        call s:ensure_flush(a:buf, l:server_name, function('s:Noop'))
    endfor
endfunction

function! s:Noop(...) abort
endfunction

function! s:is_step_error(s) abort
    return lsp#client#is_error(a:s.result[0]['response'])
endfunction

function! s:throw_step_error(s) abort
    call a:s.callback(a:s.result[0])
endfunction

function! s:new_rpc_success(message, data) abort
    return {
        \ 'response': {
        \   'message': a:message,
        \   'data': extend({ '__data__': 'vim-lsp'}, a:data),
        \ }
        \ }
endfunction

function! s:new_rpc_error(message, data) abort
    return {
        \ 'response': {
        \   'error': {
        \       'code': 0,
        \       'message': a:message,
        \       'data': extend({ '__error__': 'vim-lsp'}, a:data),
        \   },
        \ }
        \ }
endfunction

function! s:ensure_flush(buf, server_name, cb) abort
    call lsp#utils#step#start([
        \ {s->s:ensure_start(a:buf, a:server_name, s.callback)},
        \ {s->s:is_step_error(s) ? s:throw_step_error(s) : s:ensure_init(a:buf, a:server_name, s.callback)},
        \ {s->s:is_step_error(s) ? s:throw_step_error(s) : s:ensure_conf(a:buf, a:server_name, s.callback)},
        \ {s->s:is_step_error(s) ? s:throw_step_error(s) : s:ensure_open(a:buf, a:server_name, s.callback)},
        \ {s->s:is_step_error(s) ? s:throw_step_error(s) : s:ensure_changed(a:buf, a:server_name, s.callback)},
        \ {s->a:cb(s.result[0])}
        \ ])
endfunction

function! s:ensure_start(buf, server_name, cb) abort
    let l:path = lsp#utils#get_buffer_path(a:buf)

    if lsp#utils#is_remote_uri(l:path)
        let l:msg = s:new_rpc_error('ignoring start server due to remote uri', { 'server_name': a:server_name, 'uri': l:path})
        call lsp#log(l:msg)
        call a:cb(l:msg)
        return
    endif

    let l:server = s:servers[a:server_name]
    let l:server_info = l:server['server_info']
    if l:server['lsp_id'] > 0
        let l:msg = s:new_rpc_success('server already started', { 'server_name': a:server_name })
        call lsp#log(l:msg)
        call a:cb(l:msg)
        return
    endif

    let l:cmd_type = type(l:server_info['cmd'])
    if l:cmd_type == v:t_list
        let l:cmd = l:server_info['cmd']
    else
        let l:cmd = l:server_info['cmd'](l:server_info)
    endif

    if empty(l:cmd)
        let l:msg = s:new_rpc_error('ignore server start since cmd is empty', { 'server_name': a:server_name })
        call lsp#log(l:msg)
        call a:cb(l:msg)
        return
    endif

    let l:lsp_id = lsp#client#start({
        \ 'cmd': l:cmd,
        \ 'on_stderr': function('s:on_stderr', [a:server_name]),
        \ 'on_exit': function('s:on_exit', [a:server_name]),
        \ 'on_notification': function('s:on_notification', [a:server_name]),
        \ 'on_request': function('s:on_request', [a:server_name]),
        \ })

    if l:lsp_id > 0
        let l:server['lsp_id'] = l:lsp_id
        let l:msg = s:new_rpc_success('started lsp server successfully', { 'server_name': a:server_name, 'lsp_id': l:lsp_id })
        call lsp#log(l:msg)
        call a:cb(l:msg)
    else
        let l:msg = s:new_rpc_error('failed to start server', { 'server_name': a:server_name, 'cmd': l:cmd })
        call lsp#log(l:msg)
        call a:cb(l:msg)
    endif
endfunction

function! lsp#default_get_supported_capabilities(server_info) abort
    return {
    \   'workspace': {
    \       'applyEdit': v:true,
    \       'configuration': v:true
    \   }
    \ }
endfunction

function! s:ensure_init(buf, server_name, cb) abort
    let l:server = s:servers[a:server_name]

    if has_key(l:server, 'init_result')
        let l:msg = s:new_rpc_success('lsp server already initialized', { 'server_name': a:server_name, 'init_result': l:server['init_result'] })
        call lsp#log(l:msg)
        call a:cb(l:msg)
        return
    endif

    if has_key(l:server, 'init_callbacks')
        " waiting for initialize response
        call add(l:server['init_callbacks'], a:cb)
        let l:msg = s:new_rpc_success('waiting for lsp server to initialize', { 'server_name': a:server_name })
        call lsp#log(l:msg)
        return
    endif

    " server has already started, but not initialized

    let l:server_info = l:server['server_info']
    if has_key(l:server_info, 'root_uri')
        let l:root_uri = l:server_info['root_uri'](l:server_info)
    else
        let l:root_uri = lsp#utils#get_default_root_uri()
    endif

    if empty(l:root_uri)
        let l:msg = s:new_rpc_error('ignore initialization lsp server due to empty root_uri', { 'server_name': a:server_name, 'lsp_id': l:server['lsp_id'] })
        call lsp#log(l:msg)
        call a:cb(l:msg)
        return
    endif

    if has_key(l:server_info, 'capabilities')
        let l:capabilities = l:server_info['capabilities']
    else
        let l:capabilities = call(g:lsp_get_supported_capabilities[0], [server_info])
    endif

    let l:request = {
    \   'method': 'initialize',
    \   'params': {
    \     'processId': getpid(),
    \     'capabilities': l:capabilities,
    \     'rootUri': l:root_uri,
    \     'rootPath': lsp#utils#uri_to_path(l:root_uri),
    \     'trace': 'off',
    \   },
    \ }

    if has_key(l:server_info, 'initialization_options')
        let l:request.params['initializationOptions'] = l:server_info['initialization_options']
    endif

    let l:server['init_callbacks'] = [a:cb]

    call s:send_request(a:server_name, l:request)
endfunction

function! s:ensure_conf(buf, server_name, cb) abort
    let l:server = s:servers[a:server_name]
    let l:server_info = l:server['server_info']
    if has_key(l:server_info, 'workspace_config')
        let l:workspace_config = l:server_info['workspace_config']
        call s:send_notification(a:server_name, {
            \ 'method': 'workspace/didChangeConfiguration',
            \ 'params': {
            \   'settings': l:workspace_config,
            \ }
            \ })
    endif
    let l:msg = s:new_rpc_success('configuration sent', { 'server_name': a:server_name })
    call lsp#log(l:msg)
    call a:cb(l:msg)
endfunction

function! s:text_changes(buf, server_name) abort
    let l:sync_kind = lsp#capabilities#get_text_document_change_sync_kind(a:server_name)

    " When syncKind is None, return null for contentChanges.
    if l:sync_kind == 0
        return v:null
    endif

    " When syncKind is Incremental and previous content is saved.
    if l:sync_kind == 2 && has_key(s:file_content, a:buf)
        " compute diff
        let l:old_content = s:get_last_file_content(a:buf, a:server_name)
        let l:new_content = lsp#utils#buffer#_get_lines(a:buf)
        let l:changes = lsp#utils#diff#compute(l:old_content, l:new_content)
        if empty(l:changes.text) && l:changes.rangeLength ==# 0
            return []
        endif
        call s:update_file_content(a:buf, a:server_name, l:new_content)
        return [l:changes]
    endif

    let l:new_content = lsp#utils#buffer#_get_lines(a:buf)
    let l:changes = {'text': join(l:new_content, "\n")}
    call s:update_file_content(a:buf, a:server_name, l:new_content)
    return [l:changes]
endfunction

function! s:ensure_changed(buf, server_name, cb) abort
    let l:server = s:servers[a:server_name]
    let l:path = lsp#utils#get_buffer_uri(a:buf)

    let l:buffers = l:server['buffers']
    let l:buffer_info = l:buffers[l:path]

    let l:changed_tick = getbufvar(a:buf, 'changedtick')

    if l:buffer_info['changed_tick'] == l:changed_tick
        let l:msg = s:new_rpc_success('not dirty', { 'server_name': a:server_name, 'path': l:path })
        call lsp#log(l:msg)
        call a:cb(l:msg)
        return
    endif

    let l:buffer_info['changed_tick'] = l:changed_tick
    let l:buffer_info['version'] = l:buffer_info['version'] + 1

    call s:send_notification(a:server_name, {
        \ 'method': 'textDocument/didChange',
        \ 'params': {
        \   'textDocument': s:get_versioned_text_document_identifier(a:buf, l:buffer_info),
        \   'contentChanges': s:text_changes(a:buf, a:server_name),
        \ }
        \ })

    let l:msg = s:new_rpc_success('textDocument/didChange sent', { 'server_name': a:server_name, 'path': l:path })
    call lsp#log(l:msg)
    call a:cb(l:msg)
endfunction

function! s:ensure_open(buf, server_name, cb) abort
    let l:server = s:servers[a:server_name]
    let l:path = lsp#utils#get_buffer_uri(a:buf)

    if empty(l:path)
        let l:msg = s:new_rpc_error('ignore open since not a valid uri', { 'server_name': a:server_name, 'path': l:path })
        call lsp#log(l:msg)
        call a:cb(l:msg)
        return
    endif

    let l:buffers = l:server['buffers']

    if has_key(l:buffers, l:path)
        let l:msg = s:new_rpc_success('already opened', { 'server_name': a:server_name, 'path': l:path })
        call lsp#log(l:msg)
        call a:cb(l:msg)
        return
    endif

    call s:update_file_content(a:buf, a:server_name, lsp#utils#buffer#_get_lines(a:buf))

    let l:buffer_info = { 'changed_tick': getbufvar(a:buf, 'changedtick'), 'version': 1, 'uri': l:path }
    let l:buffers[l:path] = l:buffer_info

    call s:send_notification(a:server_name, {
        \ 'method': 'textDocument/didOpen',
        \ 'params': {
        \   'textDocument': s:get_text_document(a:buf, a:server_name, l:buffer_info)
        \ },
        \ })

    let l:msg = s:new_rpc_success('textDocument/open sent', { 'server_name': a:server_name, 'path': l:path, 'filetype': getbufvar(a:buf, '&filetype') })
    call lsp#log(l:msg)
    call a:cb(l:msg)
endfunction

function! s:send_request(server_name, data) abort
    let l:lsp_id = s:servers[a:server_name]['lsp_id']
    let l:data = copy(a:data)
    if has_key(l:data, 'on_notification')
        let l:data['on_notification'] = '---funcref---'
    endif
    call lsp#log_verbose('--->', l:lsp_id, a:server_name, l:data)
    call lsp#client#send_request(l:lsp_id, a:data)
endfunction

function! s:send_notification(server_name, data) abort
    let l:lsp_id = s:servers[a:server_name]['lsp_id']
    let l:data = copy(a:data)
    if has_key(l:data, 'on_notification')
        let l:data['on_notification'] = '---funcref---'
    endif
    call lsp#log_verbose('--->', l:lsp_id, a:server_name, l:data)
    call lsp#client#send_notification(l:lsp_id, a:data)
endfunction

function! s:send_response(server_name, data) abort
    let l:lsp_id = s:servers[a:server_name]['lsp_id']
    let l:data = copy(a:data)
    call lsp#log_verbose('--->', l:lsp_id, a:server_name, l:data)
    call lsp#client#send_response(l:lsp_id, a:data)
endfunction

function! s:on_stderr(server_name, id, data, event) abort
    call lsp#log_verbose('<---(stderr)', a:id, a:server_name, a:data)
endfunction

function! s:on_exit(server_name, id, data, event) abort
    call lsp#log('s:on_exit', a:id, a:server_name, 'exited', a:data)
    if has_key(s:servers, a:server_name)
        let l:server = s:servers[a:server_name]
        let l:server['lsp_id'] = 0
        let l:server['buffers'] = {}
        let l:server['exited'] = 1
        if has_key(l:server, 'init_result')
            unlet l:server['init_result']
        endif
        doautocmd User lsp_server_exit
    endif
endfunction

function! s:on_notification(server_name, id, data, event) abort
    call lsp#log_verbose('<---', a:id, a:server_name, a:data)
    let l:response = a:data['response']
    let l:server = s:servers[a:server_name]

    if lsp#client#is_server_instantiated_notification(a:data)
        if has_key(l:response, 'method')
            if g:lsp_diagnostics_enabled && l:response['method'] ==# 'textDocument/publishDiagnostics'
                call lsp#ui#vim#diagnostics#handle_text_document_publish_diagnostics(a:server_name, a:data)
            endif
        endif
    else
        let l:request = a:data['request']
        let l:method = l:request['method']
        if l:method ==# 'initialize'
            call s:handle_initialize(a:server_name, a:data)
        endif
    endif

    for l:callback_info in s:notification_callbacks
        call l:callback_info.callback(a:server_name, a:data)
    endfor
endfunction

function! s:on_request(server_name, id, request) abort
    call lsp#log_verbose('<---', a:id, a:request)
    if a:request['method'] ==# 'workspace/applyEdit'
        call lsp#utils#workspace_edit#apply_workspace_edit(a:request['params']['edit'])
        call s:send_response(a:server_name, { 'id': a:request['id'], 'result': { 'applied': v:true } })
    elseif a:request['method'] ==# 'workspace/configuration'
        let l:response_items = map(a:request['params']['items'], { key, val -> lsp#utils#workspace_config#get_value(a:server_name, val) })
        call s:send_response(a:server_name, { 'id': a:request['id'], 'result': l:response_items })
    else
        " Error returned according to json-rpc specification.
        call s:send_response(a:server_name, { 'id': a:request['id'], 'error': { 'code': -32601, 'message': 'Method not found' } })
    endif
endfunction

function! s:handle_initialize(server_name, data) abort
    let l:response = a:data['response']
    let l:server = s:servers[a:server_name]

    let l:init_callbacks = l:server['init_callbacks']
    unlet l:server['init_callbacks']

    if !lsp#client#is_error(l:response)
        let l:server['init_result'] = l:response
    else
        let l:server['failed'] = l:response['error']
        call lsp#utils#error('Failed to initialize ' . a:server_name . ' with error ' . l:response['error']['code'] . ': ' . l:response['error']['message'])
    endif

    call s:send_notification(a:server_name, { 'method': 'initialized', 'params': {} })

    for l:Init_callback in l:init_callbacks
        call l:Init_callback(a:data)
    endfor

    doautocmd User lsp_server_init
endfunction

" call lsp#get_whitelisted_servers()
" call lsp#get_whitelisted_servers(bufnr('%'))
" call lsp#get_whitelisted_servers('typescript')
function! lsp#get_whitelisted_servers(...) abort
    if a:0 == 0
        let l:buffer_filetype = &filetype
    else
        if type(a:1) == type('')
            let l:buffer_filetype = a:1
        else
            let l:buffer_filetype = getbufvar(a:1, '&filetype')
        endif
    endif

    " TODO: cache active servers per buffer
    let l:active_servers = []

    for l:server_name in keys(s:servers)
        let l:server_info = s:servers[l:server_name]['server_info']
        let l:blacklisted = 0

        if has_key(l:server_info, 'blacklist')
            for l:filetype in l:server_info['blacklist']
                if l:filetype ==? l:buffer_filetype || l:filetype ==# '*'
                    let l:blacklisted = 1
                    break
                endif
            endfor
        endif

        if l:blacklisted
            continue
        endif

        if has_key(l:server_info, 'whitelist')
            for l:filetype in l:server_info['whitelist']
                if l:filetype ==? l:buffer_filetype || l:filetype ==# '*'
                    let l:active_servers += [l:server_name]
                    break
                endif
            endfor
        endif
    endfor

    return l:active_servers
endfunction

function! s:get_text_document_text(buf, server_name) abort
    return join(s:get_last_file_content(a:buf, a:server_name), "\n")
endfunction

function! s:get_text_document(buf, server_name, buffer_info) abort
    return {
        \ 'uri': lsp#utils#get_buffer_uri(a:buf),
        \ 'languageId': &filetype,
        \ 'version': a:buffer_info['version'],
        \ 'text': s:get_text_document_text(a:buf, a:server_name),
        \ }
endfunction

function! lsp#get_text_document_identifier(...) abort
    let l:buf = a:0 > 0 ? a:1 : bufnr('%')
    return { 'uri': lsp#utils#get_buffer_uri(l:buf) }
endfunction

function! lsp#get_position(...) abort
    return { 'line': line('.') - 1, 'character': col('.') -1 }
endfunction

function! s:get_text_document_identifier(buf) abort
    return { 'uri': lsp#utils#get_buffer_uri(a:buf) }
endfunction

function! s:get_versioned_text_document_identifier(buf, buffer_info) abort
    return {
        \ 'uri': lsp#utils#get_buffer_uri(a:buf),
        \ 'version': a:buffer_info['version'],
        \ }
endfunction

function! lsp#send_request(server_name, request) abort
    let l:Cb = has_key(a:request, 'on_notification') ? a:request['on_notification'] : function('s:Noop')
    let l:request = copy(a:request)
    let l:request['on_notification'] = {id, data, event->l:Cb(data)}
    call lsp#utils#step#start([
        \ {s->s:ensure_flush(bufnr('%'), a:server_name, s.callback)},
        \ {s->s:is_step_error(s) ? l:Cb(s.result[0]) : s:send_request(a:server_name, l:request) },
        \ ])
endfunction

" omnicompletion
function! lsp#complete(...) abort
    return call('lsp#omni#complete', a:000)
endfunction

let s:didchange_queue = []
let s:didchange_timer = -1

function! s:add_didchange_queue(buf) abort
    if g:lsp_use_event_queue == 0
        for l:server_name in lsp#get_whitelisted_servers(a:buf)
            call s:ensure_flush(a:buf, l:server_name, function('s:Noop'))
        endfor
        return
    endif
    if index(s:didchange_queue, a:buf) != -1
        return
    endif
    call add(s:didchange_queue, a:buf)
    call lsp#log('s:send_didchange_queue() will be triggered')
    call timer_stop(s:didchange_timer)
    let lazy = &updatetime > 1000 ? &updatetime : 1000
    let s:didchange_timer = timer_start(lazy, function('s:send_didchange_queue'))
endfunction

function! s:send_didchange_queue(...) abort
    call lsp#log('s:send_event_queue()')
    for l:buf in s:didchange_queue
        if !bufexists(l:buf)
            continue
        endif
        for l:server_name in lsp#get_whitelisted_servers(l:buf)
            call s:ensure_flush(l:buf, l:server_name, function('s:Noop'))
        endfor
    endfor
    let s:didchange_queue = []
endfunction

" Return dict with diagnostic counts for current buffer
" { 'error': 1, 'warning': 0, 'information': 0, 'hint': 0 }
function! lsp#get_buffer_diagnostics_counts() abort
    return lsp#ui#vim#diagnostics#get_buffer_diagnostics_counts()
endfunction

" Return first error line or v:null if there are no errors
function! lsp#get_buffer_first_error_line() abort
    return lsp#ui#vim#diagnostics#get_buffer_first_error_line()
endfunction
