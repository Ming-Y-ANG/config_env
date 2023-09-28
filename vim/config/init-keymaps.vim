"======================================================================
"
" init-keymaps.vim - 按键设置，按你喜欢更改
"
"   - 快速移动
"   - 标签切换
"   - 窗口切换
"   - 终端支持
"   - 编译运行
"   - 符号搜索
"
" Created by skywind on 2018/05/30
" Last Modified: 2018/05/30 17:59:31
"
"======================================================================
" vim: set ts=4 sw=4 tw=78 noet :
"
" 快速切换tab
nnoremap <tab> :bn <cr>
nnoremap <S-tab> :bp <cr>

" 自动打开或关闭代码折叠
nnoremap <space> za

" 检测光标处文字的样式名
" 检测函数（检测光标位置处文字的样式名）
 function! <SID>SynStack()
     echo map(synstack(line('.'),col('.')),'synIDattr(v:val, "name")')
     endfunc

" 绑定检测键位（按键后样式名信息会输出在指令栏的位置）
nnoremap <leader>yi :call <SID>SynStack()<CR>"
"     "

"
"----------------------------------------------------------------------
" 设置 CTRL+HJKL 移动光标（INSERT 模式偶尔需要移动的方便些）
" 使用 SecureCRT/XShell 等终端软件需设置：Backspace sends delete
" 详见：http://www.skywind.me/blog/archives/2021
"----------------------------------------------------------------------
" inoremap <C-h> <left>
" inoremap <C-j> <down>
" inoremap <C-k> <up>
" inoremap <C-l> <right>


"----------------------------------------------------------------------
" TAB：创建，关闭，上一个，下一个，左移，右移
" 其实还可以用原生的 CTRL+PageUp, CTRL+PageDown 来切换标签
"----------------------------------------------------------------------

" noremap <silent> <leader>tc :tabnew<cr>
" noremap <silent> <leader>tq :tabclose<cr>
" noremap <silent> <leader>tn :tabnext<cr>
" noremap <silent> <leader>tp :tabprev<cr>
" noremap <silent> <leader>to :tabonly<cr>


" 左移 tab
" function! Tab_MoveLeft()
" 	let l:tabnr = tabpagenr() - 2
" 	if l:tabnr >= 0
" 		exec 'tabmove '.l:tabnr
" 	endif
" endfunc

" 右移 tab
" function! Tab_MoveRight()
" 	let l:tabnr = tabpagenr() + 1
" 	if l:tabnr <= tabpagenr('$')
" 		exec 'tabmove '.l:tabnr
" 	endif
" endfunc

" noremap <silent><leader>tl :call Tab_MoveLeft()<cr>
" noremap <silent><leader>tr :call Tab_MoveRight()<cr>
" noremap <silent><m-left> :call Tab_MoveLeft()<cr>
" noremap <silent><m-right> :call Tab_MoveRight()<cr>
"
"----------------------------------------------------------------------
" F2 在项目目录下 Grep 光标下单词，默认 C/C++/Py/Js ，扩展名自己扩充
" 支持 rg/grep/findstr ，其他类型可以自己扩充
" 不是在当前目录 grep，而是会去到当前文件所属的项目目录 project root
" 下面进行 grep，这样能方便的对相关项目进行搜索
"----------------------------------------------------------------------
" if executable('rg')
"      noremap <silent><F2> :AsyncRun! -cwd=<root> rg -n --no-heading
"                              \ --color never -g *.h -g *.c* -g *.py -g *.js -g *.vim
"                              \ <C-R><C-W> "<root>" <cr>
" elseif has('win32') || has('win64')
"      noremap <silent><F2> :AsyncRun! -cwd=<root> findstr /n /s /C:"<C-R><C-W>"
"                              \ "\%CD\%\*.h" "\%CD\%\*.c*" "\%CD\%\*.py" "\%CD\%\*.js"
"                              \ "\%CD\%\*.vim"
"                              \ <cr>
" else
"      noremap <silent><F2> :AsyncRun! -cwd=<root> grep -n -s -R <C-R><C-W>
"                              \ --include='*.h' --include='*.c*' --include='*.py'
"                              \ --include='*.js' --include='*.vim'
"                              \ '<root>' <cr>
" endif
