import os
import regex
import net.http
import json
import crypto.sha1
import time

struct WhitelistItem {
	file_path string
	regexes   []string
}

struct BlocklistRule {
	is_filename bool
	regex       string
	is_exclude  bool
}

struct PullRequestPayload {
	title string
	head  string
	base  string
	body  string
}

struct GitHubPullRequestResponse {
	html_url string
}

struct GitHubForkResponse {
	html_url string
}

struct SyncPayload {
	branch string
}

struct GitHubSyncResponse {
	message    string
	merge_type string
}

struct TreeItem {
	path string
	type string
	sha  string
}

struct GitHubTreeResponse {
	tree []TreeItem
}

struct GitHubUserResponse {
	login string
}

struct GitHubErrorDetail {
	resource string
	code     string
	field    string
	message  string
}

struct GitHubErrorResponse {
	message string
	errors  []GitHubErrorDetail
}

fn get_sanitized_git_date(randomize_tz bool) string {
	t := time.now()
	timestamp := t.unix()
	mut offset := '+0000'
	if randomize_tz {
		offsets := ['+0000', '+0100', '+0200', '+0300', '+0500', '+0530', '+0800', '+0900', '-0300',
			'-0500', '-0600', '-0800']
		idx := int(timestamp % offsets.len)
		offset = offsets[idx]
	}
	return '${timestamp} ${offset}'
}

fn get_repo_and_relative_path(file_path string) (string, string) {
	abs_path := os.real_path(file_path)
	mut current_dir := ''
	mut target_rel_path := ''
	if os.is_dir(abs_path) {
		current_dir = abs_path
		target_rel_path = '.'
	} else {
		current_dir = os.dir(abs_path)
		target_rel_path = os.file_name(abs_path)
	}
	return current_dir, target_rel_path
}

fn is_git_repo(dir string) bool {
	return os.is_dir(os.join_path(os.real_path(dir), '.git'))
}

fn is_correct_git_repo(dir string, target_url string) bool {
	if !is_git_repo(dir) {
		return false
	}
	res := exec_git_cmd(['git', '-C', dir, 'remote', 'get-url', 'origin'])
	if res.exit_code != 0 {
		return false
	}
	mut local_url := res.output.trim_space()
	o1, r1 := parse_github_owner_repo(local_url)
	o2, r2 := parse_github_owner_repo(target_url)
	if o1 != '' && o1 == o2 && r1 != '' && r1 == r2 {
		return true
	}
	mut clean_local := local_url.replace('.git', '')
	mut clean_target := target_url.replace('.git', '')
	if clean_local.contains('@') {
		clean_local = clean_local.all_after('@')
	} else if clean_local.contains('://') {
		clean_local = clean_local.all_after('://')
	}
	if clean_target.contains('@') {
		clean_target = clean_target.all_after('@')
	} else if clean_target.contains('://') {
		clean_target = clean_target.all_after('://')
	}
	if clean_local != '' && clean_local == clean_target {
		return true
	}
	return false
}

fn exec_git_cmd(args []string) os.Result {
	mut safe_args := []string{}
	if args.len > 0 && args[0] == 'git' {
		safe_args << 'git'
		safe_args << '-c'
		safe_args << 'safe.directory=*'
		safe_args << '-c'
		safe_args << 'commit.gpgsign=false'
		safe_args << '-c'
		safe_args << 'tag.gpgsign=false'
		for j in 1 .. args.len {
			safe_args << args[j]
		}
	} else {
		safe_args = args.clone()
	}
	return os.exec(safe_args)
}

fn run_git_cmd(args []string, error_msg string) bool {
	res := exec_git_cmd(args)
	if res.exit_code != 0 {
		eprintln('Error: ${error_msg}. Output: ${res.output.trim_space()}')
		return false
	}
	return true
}

fn git_add_files(files []string) bool {
	if files.len == 0 {
		return true
	}
	mut i := 0
	for i < files.len {
		mut chunk := ['git', 'add', '--force']
		end := if i + 100 < files.len { i + 100 } else { files.len }
		for j in i .. end {
			chunk << files[j]
		}
		if !run_git_cmd(chunk, 'Failed to add files') {
			return false
		}
		i += 100
	}
	return true
}

fn git_rm_files(files []string) bool {
	if files.len == 0 {
		return true
	}
	mut i := 0
	for i < files.len {
		mut chunk := ['git', 'rm', '-r', '--ignore-unmatch']
		end := if i + 100 < files.len { i + 100 } else { files.len }
		for j in i .. end {
			chunk << files[j]
		}
		if !run_git_cmd(chunk, 'Failed to remove files') {
			return false
		}
		i += 100
	}
	return true
}

fn delete_git_dir(dir string) {
	git_dir := os.join_path(dir, '.git')
	if os.exists(git_dir) {
		os.exec(['rm', '-rf', git_dir])
		if os.exists(git_dir) {
			os.rmdir_all(git_dir) or {}
		}
	}
}

fn get_commit_list(branch string) []string {
	res := exec_git_cmd(['git', 'rev-list', '--reverse', branch])
	if res.exit_code != 0 {
		return []string{}
	}
	mut list := []string{}
	for line in res.output.split('\n') {
		trimmed := line.trim_space()
		if trimmed != '' {
			list << trimmed
		}
	}
	return list
}

fn get_commit_info(sha string) string {
	res := exec_git_cmd(['git', 'log', '-1', '--format=%h - %s (%an)', sha])
	if res.exit_code == 0 {
		return res.output.trim_space()
	}
	return sha
}

fn ensure_email(email string) string {
	if email != '' {
		return email
	}
	res := exec_git_cmd(['git', 'config', '--get', 'user.email'])
	if res.exit_code == 0 {
		existing_email := res.output.trim_space()
		if existing_email != '' {
			return existing_email
		}
	}
	return 'noreply@github.com'
}

fn ensure_name(name string) string {
	if name != '' {
		return name
	}
	res := exec_git_cmd(['git', 'config', '--get', 'user.name'])
	if res.exit_code == 0 {
		existing_name := res.output.trim_space()
		if existing_name != '' {
			return existing_name
		}
	}
	return 'Anonymous'
}

fn get_current_branch() string {
	res := exec_git_cmd(['git', 'branch', '--show-current'])
	if res.exit_code == 0 {
		branch := res.output.trim_space()
		if branch != '' {
			return branch
		}
	}
	res_default := exec_git_cmd(['git', 'config', '--get', 'init.defaultBranch'])
	if res_default.exit_code == 0 {
		db := res_default.output.trim_space()
		if db != '' {
			return db
		}
	}
	return 'main'
}

fn get_remote_origin_url() string {
	res := exec_git_cmd(['git', 'config', '--get', 'remote.origin.url'])
	if res.exit_code == 0 {
		return res.output.trim_space()
	}
	return ''
}

fn parse_github_owner_repo(url string) (string, string) {
	mut clean_url := url.trim_space()
	if clean_url.ends_with('.git') {
		clean_url = clean_url[0 .. clean_url.len - 4]
	}
	if !clean_url.contains('github.com') {
		return '', ''
	}
	mut path := ''
	if clean_url.contains('github.com/') {
		path = clean_url.all_after('github.com/')
	} else if clean_url.contains('github.com:') {
		path = clean_url.all_after('github.com:')
	} else {
		return '', ''
	}
	parts := path.split('/')
	if parts.len >= 2 {
		return parts[0], parts[1]
	}
	return '', ''
}

fn get_local_file_git_sha(abs_path string) ?string {
	content := os.read_file(abs_path) or { return none }
	header := 'blob ${content.len}'
	mut data := []u8{}
	for b in header.bytes() {
		data << b
	}
	data << 0
	for b in content.bytes() {
		data << b
	}
	return sha1.sum(data).hex()
}

fn list_files_recursively(path string) []string {
	if !os.is_dir(path) {
		return [path]
	}
	mut res := []string{}
	files := os.ls(path) or { return [] }
	for file in files {
		full_path := os.join_path(path, file)
		if os.is_dir(full_path) && !os.is_link(full_path) {
			sub_files := list_files_recursively(full_path)
			for sub_file in sub_files {
				res << sub_file
			}
		} else {
			res << full_path
		}
	}
	return res
}

fn setup_request_proxy(mut req http.Request) {
	mut proxy_env := os.getenv('HTTPS_PROXY')
	if proxy_env == '' {
		proxy_env = os.getenv('HTTP_PROXY')
	}
	if proxy_env != '' {
		if p := http.new_http_proxy(proxy_env) {
			req.proxy = p
		}
	}
}

fn add_anonymizing_headers(mut req http.Request, token string) {
	req.add_custom_header('Authorization', 'Bearer ${token}') or {}
	req.add_custom_header('Accept', 'application/vnd.github+json') or {}
	req.add_custom_header('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36') or {}
}

fn get_github_username(token string) string {
	api_url := 'https://api.github.com/user'
	mut req := http.new_request(.get, api_url, '')
	setup_request_proxy(mut req)
	add_anonymizing_headers(mut req, token)
	res := req.do() or { return '' }
	if res.status_code == 200 {
		response := json.decode(GitHubUserResponse, res.body) or { return '' }
		return response.login
	}
	return ''
}

fn push_to_remote(formatted_url string, branch string, force_flag string, sync_lease bool) bool {
	mut original_url := ''
	mut has_origin := false
	res_remote := exec_git_cmd(['git', 'remote', 'get-url', 'origin'])
	if res_remote.exit_code == 0 {
		has_origin = true
		original_url = res_remote.output.trim_space()
		exec_git_cmd(['git', 'remote', 'set-url', 'origin', formatted_url])
	} else {
		exec_git_cmd(['git', 'remote', 'add', 'origin', formatted_url])
	}
	if sync_lease {
		println('Synchronizing lease with remote...')
		exec_git_cmd(['git', 'fetch', 'origin', '${branch}:refs/remotes/origin/${branch}'])
	}
	mut push_args := ['git', 'push', 'origin', branch]
	if force_flag != '' {
		push_args << force_flag
	}
	mut res := exec_git_cmd(push_args)
	if res.exit_code != 0 {
		err_out := res.output.trim_space()
		if (force_flag != '' && (err_out.contains('stale info') || err_out.contains('fetch first')))
			|| err_out.contains('non-fast-forward') {
			if force_flag != '--force' && force_flag != '' {
				println('Warning: Push rejected by GitHub due to divergent history. Retrying with absolute force (--force)...')
				mut fallback_args := ['git', 'push', 'origin', branch, '--force']
				res = exec_git_cmd(fallback_args)
				if res.exit_code != 0 {
					eprintln('Error: Failed to update remote even with --force. Output:\n${res.output.trim_space()}')
				} else {
					println('Force push successful on fallback.')
				}
			} else {
				eprintln('Error: Failed to update remote. Output:\n${err_out}')
			}
		} else {
			eprintln('Error: Failed to update remote. Output:\n${err_out}')
		}
	}
	if has_origin {
		if original_url != '' {
			exec_git_cmd(['git', 'remote', 'set-url', 'origin', original_url])
		}
	} else {
		exec_git_cmd(['git', 'remote', 'remove', 'origin'])
	}
	return res.exit_code == 0
}

fn get_gitless_changed_files(repo_dir string, rel_path string, git_url string, token string, branch string, lazy_push bool) []string {
	owner, repo := parse_github_owner_repo(git_url)
	if owner == '' || repo == '' {
		println('Warning: Smart remote comparison is only supported for GitHub. Treating all local files as new/modified.')
		mut changed_files := []string{}
		target_abs_path := os.join_path(repo_dir, rel_path)
		mut local_files := []string{}
		if os.is_dir(target_abs_path) {
			local_files = list_files_recursively(target_abs_path)
		} else if os.exists(target_abs_path) {
			local_files = [target_abs_path]
		}
		for abs_file in local_files {
			mut file_rel := abs_file.replace(os.real_path(repo_dir), '')
			file_rel = file_rel.trim_left('/\\').replace('\\', '/')
			if file_rel.starts_with('.git/') || file_rel == '.git' || file_rel == 'fastgit_block'
				|| file_rel == 'fastgit' {
				continue
			}
			changed_files << file_rel
		}
		return changed_files
	}
	println('Fetching file tree directly from remote GitHub repository...')
	api_url := 'https://api.github.com/repos/${owner}/${repo}/git/trees/${branch}?recursive=1'
	mut req := http.new_request(.get, api_url, '')
	setup_request_proxy(mut req)
	add_anonymizing_headers(mut req, token)
	res := req.do() or {
		println('Warning: Failed to fetch remote tree from GitHub. Proceeding with assuming files are new.')
		return []string{}
	}
	mut remote_files := map[string]string{}
	if res.status_code == 200 {
		response := json.decode(GitHubTreeResponse, res.body) or {
			println('Warning: Failed to parse remote tree. Treating all local files as new.')
			GitHubTreeResponse{}
		}
		for item in response.tree {
			if item.type == 'blob' {
				remote_files[item.path] = item.sha
			}
		}
	} else {
		println('Remote repository empty or branch not found. Treating all local files as new.')
	}
	mut changed_files := []string{}
	target_abs_path := os.real_path(os.join_path(repo_dir, rel_path))
	mut local_files := []string{}
	if os.is_dir(target_abs_path) {
		local_files = list_files_recursively(target_abs_path)
	} else if os.exists(target_abs_path) {
		local_files = [target_abs_path]
	}
	for abs_file in local_files {
		mut file_rel := abs_file.replace(os.real_path(repo_dir), '')
		file_rel = file_rel.trim_left('/\\').replace('\\', '/')
		if file_rel.starts_with('.git/') || file_rel == '.git' || file_rel == 'fastgit_block'
			|| file_rel == 'fastgit' {
			continue
		}
		local_sha := get_local_file_git_sha(abs_file) or { continue }
		remote_sha := remote_files[file_rel] or { '' }
		if local_sha != remote_sha {
			changed_files << file_rel
		}
	}
	if !lazy_push {
		for remote_path, _ in remote_files {
			if rel_path == '.' || rel_path == '' || remote_path.starts_with(rel_path) {
				local_abs_path := os.join_path(repo_dir, remote_path)
				if !os.exists(local_abs_path) {
					changed_files << remote_path
				}
			}
		}
	}
	return changed_files
}

fn create_pull_request(git_url string, token string, title string, base string, pr_body string) {
	owner, repo := parse_github_owner_repo(git_url)
	if owner == '' || repo == '' {
		println('Error: Pull Request command is only supported for GitHub repositories.')
		return
	}
	head_branch := get_current_branch()
	username := get_github_username(token)
	mut head := head_branch
	if username != '' {
		head = '${username}:${head_branch}'
	}
	println('Preparing to create Pull Request from branch "${head}" into "${base}" for ${owner}/${repo}...')
	if head_branch == base && owner == username {
		println('Error: Head branch and base branch cannot be the same ("${head_branch}").')
		return
	}
	api_url := 'https://api.github.com/repos/${owner}/${repo}/pulls'
	payload := PullRequestPayload{
		title: title
		head:  head
		base:  base
		body:  pr_body
	}
	json_payload := json.encode(payload)
	mut req := http.new_request(.post, api_url, json_payload)
	setup_request_proxy(mut req)
	req.add_header(.content_type, 'application/json')
	add_anonymizing_headers(mut req, token)
	res := req.do() or {
		println('Error: Failed to send request.')
		return
	}
	output := res.body.trim_space()
	if res.status_code == 201 {
		response := json.decode(GitHubPullRequestResponse, output) or {
			println('Failed to parse API Response. Raw response:')
			println(output)
			return
		}
		if response.html_url != '' {
			println('Successfully created Pull Request!')
			println('PR Link: ${response.html_url}')
			return
		}
	}
	err_response := json.decode(GitHubErrorResponse, output) or {
		println('Failed to create Pull Request. GitHub API Response:')
		println(output)
		return
	}
	println('Error: Failed to create Pull Request.')
	println('Message: ${err_response.message}')
	for err in err_response.errors {
		if err.message != '' {
			println('Detail: ${err.message}')
		}
	}
}

fn fork_repository(git_url string, token string) {
	owner, repo := parse_github_owner_repo(git_url)
	if owner == '' || repo == '' {
		println('Error: Fork command is only supported for GitHub repositories.')
		return
	}
	println('Requesting to fork repository ${owner}/${repo} to your account...')
	api_url := 'https://api.github.com/repos/${owner}/${repo}/forks'
	mut req := http.new_request(.post, api_url, '{}')
	setup_request_proxy(mut req)
	req.add_header(.content_type, 'application/json')
	add_anonymizing_headers(mut req, token)
	res := req.do() or {
		println('Error: Failed to send fork command.')
		return
	}
	output := res.body.trim_space()
	response := json.decode(GitHubForkResponse, output) or {
		println('Failed to parse API Response. Raw response:')
		println(output)
		return
	}
	if response.html_url != '' {
		println('Successfully requested fork! It might take a moment to be created by GitHub.')
		println('Forked URL: ${response.html_url}')
	} else {
		println('Failed to fork repository. GitHub API Response:')
		println(output)
	}
}

fn sync_fork_with_upstream(git_url string, token string, branch string) {
	owner, repo := parse_github_owner_repo(git_url)
	if owner == '' || repo == '' {
		println('Error: Sync command is only supported for GitHub repositories.')
		return
	}
	println('Syncing fork ${owner}/${repo} (branch: "${branch}") with upstream...')
	api_url := 'https://api.github.com/repos/${owner}/${repo}/merge-upstream'
	payload := SyncPayload{
		branch: branch
	}
	json_payload := json.encode(payload)
	mut req := http.new_request(.post, api_url, json_payload)
	setup_request_proxy(mut req)
	req.add_header(.content_type, 'application/json')
	add_anonymizing_headers(mut req, token)
	res := req.do() or {
		println('Error: Failed to send sync command.')
		return
	}
	output := res.body.trim_space()
	response := json.decode(GitHubSyncResponse, output) or {
		if output.contains('conflict') {
			println('Error: Could not automatically sync fork due to merge conflicts. Please resolve manually.')
		} else {
			println('Sync process completed. GitHub Response:')
			println(output)
		}
		return
	}
	if response.message != '' {
		println('GitHub API response: ${response.message}')
		if response.merge_type != '' {
			println('Merge Type: ${response.merge_type}')
		}
	} else {
		println('Sync process completed. GitHub Response:')
		println(output)
	}
}

fn format_git_url(raw_url string, token string) string {
	mut url := raw_url.trim_space()
	if url.starts_with('git@') {
		content := url.all_after('git@')
		parts := content.split(':')
		if parts.len >= 2 {
			domain := parts[0]
			path := parts[1]
			url = 'https://' + domain + '/' + path
		}
	} else if url.starts_with('ssh://git@') {
		content := url.all_after('ssh://git@')
		parts := content.split('/')
		if parts.len >= 2 {
			domain := parts[0]
			path := parts[1..].join('/')
			url = 'https://' + domain + '/' + path
		}
	}
	if url.starts_with('https://') {
		return 'https://' + token + '@' + url.all_after('https://')
	}
	return url
}

fn is_file_path(s string) bool {
	if os.exists(s) {
		return true
	}
	if s.contains('/') || s.contains('\\') || s.contains('.') {
		chars := ['*', '[', ']', '(', ')', '|', '+', '^', '$', '{', '}']
		for c in chars {
			if s.contains(c) {
				return false
			}
		}
		return true
	}
	return false
}

fn match_regex(text string, pattern string) bool {
	mut re := regex.regex_opt(pattern) or {
		eprintln('Error: Invalid regex pattern: ${pattern}')
		exit(1)
	}
	start, _ := re.find(text)
	return start != -1
}

fn validate_and_filter_files(changed_files []string) ?[]string {
	if !os.exists('fastgit_block') {
		return changed_files
	}
	lines := os.read_lines('fastgit_block') or { return changed_files }
	mut whitelist := []WhitelistItem{}
	mut blocklist := []BlocklistRule{}
	mut current_file_path := ''
	mut current_regexes := []string{}
	for line in lines {
		trimmed := line.trim_space()
		if trimmed == '' || trimmed.starts_with('#') {
			continue
		}
		if trimmed.starts_with('filename + ') {
			pattern := trimmed.all_after('filename + ').trim_space()
			blocklist << BlocklistRule{
				is_filename: true
				regex:       pattern
				is_exclude:  false
			}
		} else if trimmed.starts_with('filename - ') {
			pattern := trimmed.all_after('filename - ').trim_space()
			blocklist << BlocklistRule{
				is_filename: true
				regex:       pattern
				is_exclude:  true
			}
		} else if trimmed.starts_with('file + ') {
			pattern := trimmed.all_after('file + ').trim_space()
			if is_file_path(pattern) {
				if current_file_path != '' {
					whitelist << WhitelistItem{
						file_path: current_file_path
						regexes:   current_regexes.clone()
					}
				}
				current_file_path = pattern
				current_regexes = []string{}
			} else {
				if current_file_path != '' {
					current_regexes << pattern
				} else {
					blocklist << BlocklistRule{
						is_filename: false
						regex:       pattern
						is_exclude:  false
					}
				}
			}
		} else if trimmed.starts_with('file - ') {
			pattern := trimmed.all_after('file - ').trim_space()
			blocklist << BlocklistRule{
				is_filename: false
				regex:       pattern
				is_exclude:  true
			}
		}
	}
	if current_file_path != '' {
		whitelist << WhitelistItem{
			file_path: current_file_path
			regexes:   current_regexes.clone()
		}
	}
	mut filtered_files := []string{}
	if whitelist.len > 0 {
		for file in changed_files {
			mut allowed := false
			mut matched_item := WhitelistItem{}
			for item in whitelist {
				if file == item.file_path {
					allowed = true
					matched_item = item
					break
				}
			}
			if !allowed {
				println('Error: File "${file}" is not whitelisted in fastgit_block!')
				return none
			}
			content := os.read_file(file) or { '' }
			for pattern in matched_item.regexes {
				if match_regex(content, pattern) {
					println('Error: Blocked pattern "${pattern}" matched in whitelisted file "${file}"!')
					return none
				}
			}
			filtered_files << file
		}
	} else {
		for file in changed_files {
			mut should_exclude := false
			mut blocked := false
			mut block_reason := ''
			for rule in blocklist {
				if rule.is_filename {
					if match_regex(file, rule.regex) {
						if rule.is_exclude {
							should_exclude = true
							break
						} else {
							blocked = true
							block_reason = 'Filename "${file}" matches blocked pattern "${rule.regex}"!'
							break
						}
					}
				} else {
					content := os.read_file(file) or { '' }
					if match_regex(content, rule.regex) {
						if rule.is_exclude {
							should_exclude = true
							break
						} else {
							blocked = true
							block_reason = 'Content in "${file}" matches blocked pattern "${rule.regex}"!'
							break
						}
					}
				}
			}
			if blocked {
				println('Error: ' + block_reason)
				return none
			}
			if !should_exclude {
				filtered_files << file
			} else {
				println('Skipping file: ${file} (matched exclusion rule)')
			}
		}
	}
	return filtered_files
}

fn confirm_upload(changed_files []string, auto_confirm bool) bool {
	if auto_confirm {
		return true
	}
	println('The following files are staged/changed for upload:')
	for file in changed_files {
		println(' -> ${file}')
	}
	ans := os.input('Do you want to proceed with the push? (y/n): ').trim_space().to_lower()
	return ans == 'y' || ans == 'yes'
}

fn print_usage() {
	println('FastGit - A smart and anonymous tool for working with GitHub')
	println('Usage:')
	println('  ./fastgit <git_url> <commit_message> <file_or_folder_path>')
	println('  ./fastgit <git_url> <file_or_folder_path>')
	println('  ./fastgit over <git_url> <commit_message> <file_or_folder_path>')
	println('  ./fastgit ctrlz <git_url>')
	println('  ./fastgit remove <git_url> <commit_sha>')
	println('  ./fastgit pr <git_url> [title] [base_branch] [body]')
	println('  ./fastgit fork <git_url>')
	println('  ./fastgit sync <git_url> [branch_name]')
	println('\nOptions:')
	println('  -e, --email    GitHub anonymous email (Anonymous / No-Reply)')
	println('  -n, --name     Git author name')
	println('  -t, --token    GitHub Personal Access Token')
	println('  -y, --yes      Skip upload confirmation')
	println('  -b, --branch   Target branch (default: current branch or main)')
	println('  -l, --lazy     Lazy push (do not delete remote files that are missing locally)')
	println('  -f, --force    Use absolute force push (bypasses safety and overrides default --force-with-lease)')
	println('\nNote: You can also set FASTGIT_EMAIL, FASTGIT_NAME and FASTGIT_TOKEN environment variables.')
}

fn main() {
	os.setenv('GIT_CONFIG_COUNT', '3', true)
	os.setenv('GIT_CONFIG_KEY_0', 'safe.directory', true)
	os.setenv('GIT_CONFIG_VALUE_0', '*', true)
	os.setenv('GIT_CONFIG_KEY_1', 'commit.gpgsign', true)
	os.setenv('GIT_CONFIG_VALUE_1', 'false', true)
	os.setenv('GIT_CONFIG_KEY_2', 'tag.gpgsign', true)
	os.setenv('GIT_CONFIG_VALUE_2', 'false', true)
	if os.args.len < 2 {
		print_usage()
		return
	}
	mut positional_args := []string{}
	mut email := os.getenv('FASTGIT_EMAIL')
	mut name := os.getenv('FASTGIT_NAME')
	mut token := os.getenv('FASTGIT_TOKEN')
	mut branch_override := os.getenv('FASTGIT_BRANCH')
	mut auto_confirm := os.getenv('FASTGIT_AUTO_CONFIRM') == 'true'
	mut lazy_push := false
	mut use_absolute_force := false
	mut i := 0
	for i < os.args.len {
		arg := os.args[i]
		if arg == '--email' || arg == '-e' {
			if i + 1 < os.args.len {
				email = os.args[i + 1]
				i += 2
			} else {
				i++
			}
		} else if arg == '--name' || arg == '-n' {
			if i + 1 < os.args.len {
				name = os.args[i + 1]
				i += 2
			} else {
				i++
			}
		} else if arg == '--token' || arg == '-t' {
			if i + 1 < os.args.len {
				token = os.args[i + 1]
				i += 2
			} else {
				i++
			}
		} else if arg == '--branch' || arg == '-b' {
			if i + 1 < os.args.len {
				branch_override = os.args[i + 1]
				i += 2
			} else {
				i++
			}
		} else if arg == '--yes' || arg == '-y' {
			auto_confirm = true
			i++
		} else if arg == '--lazy' || arg == '-lazy' || arg == '-l' {
			lazy_push = true
			i++
		} else if arg == '--force' || arg == '-f' {
			use_absolute_force = true
			i++
		} else {
			positional_args << arg
			i++
		}
	}
	if positional_args.len < 2 {
		print_usage()
		return
	}
	if token == '' {
		secure_token := os.input_password('Enter your GitHub Personal Access Token (securely): ') or {
			os.input('Enter your GitHub Personal Access Token: ')
		}
		token = secure_token.trim_space()
		if token == '' {
			println('Error: Token cannot be empty.')
			return
		}
	}
	original_wd := os.getwd()
	force_flag := if use_absolute_force { '--force' } else { '--force-with-lease' }
	email = ensure_email(email)
	name = ensure_name(name)
	sanitized_date := get_sanitized_git_date(true)
	os.setenv('GIT_AUTHOR_NAME', name, true)
	os.setenv('GIT_AUTHOR_EMAIL', email, true)
	os.setenv('GIT_COMMITTER_NAME', name, true)
	os.setenv('GIT_COMMITTER_EMAIL', email, true)
	os.setenv('GIT_AUTHOR_DATE', sanitized_date, true)
	os.setenv('GIT_COMMITTER_DATE', sanitized_date, true)
	if positional_args[1] == 'fork' {
		if positional_args.len < 3 {
			print_usage()
			return
		}
		git_url := positional_args[2]
		fork_repository(git_url, token)
		return
	}
	if positional_args[1] == 'sync' {
		if positional_args.len < 3 {
			print_usage()
			return
		}
		git_url := positional_args[2]
		mut branch := 'main'
		if branch_override != '' {
			branch = branch_override
		} else if positional_args.len >= 4 {
			branch = positional_args[3]
		}
		sync_fork_with_upstream(git_url, token, branch)
		if is_git_repo(os.getwd()) {
			local_url := get_remote_origin_url()
			if local_url != '' {
				local_owner, local_repo := parse_github_owner_repo(local_url)
				target_owner, target_repo := parse_github_owner_repo(git_url)
				if local_owner == target_owner && local_repo == target_repo {
					println('Local repository matches. Pulling synced changes to local directory...')
					run_git_cmd(['git', 'pull', 'origin', branch], 'Failed to pull changes')
				}
			}
		}
		return
	}
	if positional_args[1] == 'pr' {
		if positional_args.len < 4 {
			print_usage()
			return
		}
		git_url := positional_args[2]
		title := positional_args[3]
		mut base_branch := 'main'
		mut pr_body := ''
		if positional_args.len >= 5 {
			base_branch = positional_args[4]
		}
		if positional_args.len >= 6 {
			pr_body = positional_args[5]
		}
		if !is_git_repo(os.getwd()) {
			println('Error: current directory is not a git repository. Cannot make PR.')
			return
		}
		head_branch := get_current_branch()
		owner, _ := parse_github_owner_repo(git_url)
		username := get_github_username(token)
		if head_branch == base_branch && owner == username {
			println('Error: You are trying to create a Pull Request from "${head_branch}" into "${base_branch}" on your own repository.')
			println('GitHub does not allow creating a PR between identical branches in the same repository.')
			println('To fix this, please create a new branch, commit your changes, and try again:')
			println('  git checkout -b my-new-branch')
			println('  git add .')
			println('  git commit -m "your message"')
			return
		}
		println('Ensuring your local branch "${head_branch}" is pushed and up-to-date on GitHub...')
		status_res := exec_git_cmd(['git', 'status', '--porcelain'])
		if status_res.exit_code == 0 && status_res.output.trim_space() != '' {
			println('Warning: You have uncommitted changes in your working directory. They will not be included in the PR unless you commit them.')
		}
		local_remote_url := get_remote_origin_url()
		formatted_url := format_git_url(git_url, token)
		mut push_url := formatted_url
		if local_remote_url != '' {
			push_url = format_git_url(local_remote_url, token)
		}
		if push_to_remote(push_url, head_branch, '', false) {
			println('Local branch successfully synchronized with remote.')
		} else {
			println('Warning: Failed to automatically push local branch to remote. Attempting to create PR anyway...')
		}
		create_pull_request(git_url, token, title, base_branch, pr_body)
		return
	}
	if positional_args[1] == 'ctrlz' {
		if positional_args.len < 3 {
			print_usage()
			return
		}
		git_url := positional_args[2]
		mut branch := 'main'
		if branch_override != '' {
			branch = branch_override
		} else {
			branch = get_current_branch()
		}
		formatted_url := format_git_url(git_url, token)
		mut use_temp_repo := false
		if !is_correct_git_repo(os.getwd(), git_url) {
			use_temp_repo = true
			println('Note: Current directory is not the exact repository for this URL. Using a temporary clone for safety.')
		}
		mut temp_dir := ''
		defer {
			if use_temp_repo && temp_dir != '' {
				println('Cleaning up temporary local repository...')
				os.chdir(original_wd) or {}
				os.rmdir_all(temp_dir) or {}
			}
		}
		if use_temp_repo {
			temp_dir = os.join_path(os.temp_dir(), 'fastgit_ctrlz_temp')
			os.rmdir_all(temp_dir) or {}
			os.mkdir(temp_dir) or {
				eprintln('Error: Failed to create temporary directory.')
				return
			}
			os.chdir(temp_dir) or {
				eprintln('Error: Failed to change to temporary directory.')
				return
			}
			println('Initializing temporary local repository for rollback...')
			if !run_git_cmd(['git', 'init'], 'Failed to initialize repository') {
				return
			}
			if !run_git_cmd(['git', 'symbolic-ref', 'HEAD', 'refs/heads/' + branch], 'Failed to set target branch') {
				return
			}
			if !run_git_cmd(['git', 'remote', 'add', 'origin', formatted_url], 'Failed to add remote origin') {
				return
			}
			println('Fetching last 2 commits from remote...')
			fetch_res := exec_git_cmd(['git', 'fetch', '--depth', '2', 'origin', '${branch}:refs/remotes/origin/${branch}'])
			if fetch_res.exit_code != 0 {
				eprintln('Error: Failed to fetch history from remote. Maybe the branch is empty.')
				return
			}
			if !run_git_cmd(['git', 'reset', '--hard', 'origin/' + branch], 'Failed to sync with remote history') {
				return
			}
		} else {
			if branch_override != '' {
				if !run_git_cmd(['git', 'checkout', '-B', branch], 'Failed to checkout branch') {
					return
				}
			}
			println('Updating remote lease before commit removal...')
			exec_git_cmd(['git', 'fetch', 'origin', '${branch}:refs/remotes/origin/${branch}'])
		}
		commits := get_commit_list(branch)
		if commits.len == 0 {
			println('Error: Failed to retrieve commit history.')
			return
		}
		target_sha := if commits.len == 1 { commits[0] } else { commits[commits.len - 1] }
		commit_info := get_commit_info(target_sha)
		println('\nWarning: This action will completely remove the following commit from local and remote history:')
		println(' -> ${commit_info}')
		if !auto_confirm {
			ans := os.input('Do you want to proceed with this rollback? (y/n): ').trim_space().to_lower()
			if ans != 'y' && ans != 'yes' {
				println('Rollback canceled.')
				return
			}
		}
		if commits.len == 1 {
			println('The repository has only 1 commit. Resetting repository to an empty state (keeping your files)...')
			if !run_git_cmd(['git', 'checkout', '--orphan', 'temp_orphan'], 'Failed to create orphan branch') {
				return
			}
			exec_git_cmd(['git', 'rm', '-rf', '--cached', '.'])
			if !run_git_cmd(['git', 'commit', '--allow-empty', '-m', 'Reset repository to empty state'],
				'Failed to commit empty state') {
				return
			}
			if !run_git_cmd(['git', 'branch', '-M', 'temp_orphan', branch], 'Failed to rename branch') {
				return
			}
		} else {
			println('Rolling back the last commit locally (keeping your files)...')
			if !run_git_cmd(['git', 'reset', 'HEAD~1'], 'Failed to reset commit locally.') {
				return
			}
		}
		println('Pushing roll-back to remote (${force_flag})...')
		if !push_to_remote(formatted_url, branch, force_flag, false) {
			return
		}
		println('Successfully removed the last commit from local and remote.')
		return
	}
	if positional_args[1] == 'remove' {
		if positional_args.len < 4 {
			print_usage()
			return
		}
		git_url := positional_args[2]
		commit_sha := positional_args[3]
		mut branch := 'main'
		if branch_override != '' {
			branch = branch_override
		} else {
			branch = get_current_branch()
		}
		formatted_url := format_git_url(git_url, token)
		mut use_temp_repo := false
		if !is_correct_git_repo(os.getwd(), git_url) {
			use_temp_repo = true
			println('Note: Current directory is not the exact repository for this URL. Using a temporary clone for safety.')
		}
		mut temp_dir := ''
		defer {
			if use_temp_repo && temp_dir != '' {
				println('Cleaning up temporary local repository...')
				os.chdir(original_wd) or {}
				os.rmdir_all(temp_dir) or {}
			}
		}
		if use_temp_repo {
			temp_dir = os.join_path(os.temp_dir(), 'fastgit_remove_temp')
			os.rmdir_all(temp_dir) or {}
			os.mkdir(temp_dir) or {
				eprintln('Error: Failed to create temporary directory.')
				return
			}
			os.chdir(temp_dir) or {
				eprintln('Error: Failed to change to temporary directory.')
				return
			}
			println('Initializing temporary local repository for commit removal...')
			if !run_git_cmd(['git', 'init'], 'Failed to initialize repository') {
				return
			}
			if !run_git_cmd(['git', 'symbolic-ref', 'HEAD', 'refs/heads/' + branch], 'Failed to set target branch') {
				return
			}
			if !run_git_cmd(['git', 'remote', 'add', 'origin', formatted_url], 'Failed to add remote origin') {
				return
			}
			println('Fetching full branch history from remote...')
			fetch_res := exec_git_cmd(['git', 'fetch', 'origin', '${branch}:refs/remotes/origin/${branch}'])
			if fetch_res.exit_code != 0 {
				eprintln('Error: Failed to fetch history from remote. Maybe the branch is empty.')
				return
			}
			if !run_git_cmd(['git', 'reset', '--hard', 'origin/' + branch], 'Failed to sync with remote history') {
				return
			}
		} else {
			if branch_override != '' {
				if !run_git_cmd(['git', 'checkout', '-B', branch], 'Failed to checkout branch') {
					return
				}
			}
			println('Updating remote lease before commit removal...')
			exec_git_cmd(['git', 'fetch', 'origin', '${branch}:refs/remotes/origin/${branch}'])
		}
		commit_info := get_commit_info(commit_sha)
		println('\nWarning: This action will completely remove the following commit from the history:')
		println(' -> ${commit_info}')
		if !auto_confirm {
			ans := os.input('Do you want to proceed with removing this commit? (y/n): ').trim_space().to_lower()
			if ans != 'y' && ans != 'yes' {
				println('Operation canceled.')
				return
			}
		}
		println('Removing commit ${commit_sha} from history...')
		commits := get_commit_list(branch)
		if commits.len == 0 {
			println('Error: Failed to retrieve commit history.')
			return
		}
		mut is_root := false
		if commits.len > 0 && commits[0] == commit_sha {
			is_root = true
		}
		if is_root {
			if commits.len == 1 {
				println('Commit ${commit_sha} is the only commit in the repository. Resetting repository to an empty state (keeping your files)...')
				if !run_git_cmd(['git', 'checkout', '--orphan', 'temp_orphan'], 'Failed to create orphan branch') {
					return
				}
				exec_git_cmd(['git', 'rm', '-rf', '--cached', '.'])
				if !run_git_cmd(['git', 'commit', '--allow-empty', '-m', 'Reset repository to empty state'],
					'Failed to commit empty state') {
					return
				}
				if !run_git_cmd(['git', 'branch', '-M', 'temp_orphan', branch], 'Failed to rename branch') {
					return
				}
			} else {
				c2 := commits[1]
				println('Commit ${commit_sha} is the root commit. Re-writing history to make commit ${c2} the new root commit...')
				if !run_git_cmd(['git', 'checkout', '--orphan', 'temp_orphan', c2], 'Failed to create orphan branch') {
					return
				}
				if !run_git_cmd(['git', 'commit', '-C', c2], 'Failed to commit new root') {
					return
				}
				if commits.len > 2 {
					println('Replaying subsequent commits...')
					if !run_git_cmd(['git', 'cherry-pick', c2 + '..' + branch], 'Failed to cherry-pick subsequent commits') {
						println('Aborting cherry-pick...')
						exec_git_cmd(['git', 'cherry-pick', '--abort'])
						return
					}
				}
				if !run_git_cmd(['git', 'branch', '-M', 'temp_orphan', branch], 'Failed to rename branch') {
					return
				}
			}
		} else {
			os.setenv('GIT_EDITOR', 'true', true)
			rebase_res := exec_git_cmd(['git', 'rebase', '-X', 'theirs', '--onto', commit_sha + '~1',
				commit_sha, branch])
			if rebase_res.exit_code != 0 {
				println('Warning: Automatic conflict resolution failed. Structural conflict detected.')
				if use_temp_repo {
					println('Temporary repository path: ' + temp_dir)
				} else {
					println('Please resolve conflicts in the current directory.')
				}
				println('Steps:')
				println('1. Open conflicted files and resolve the merge conflicts.')
				println('2. Run "git add <resolved_files>" to stage them.')
				println('3. Come back here and type "y" to continue.')
				mut resolved := false
				for {
					ans := os.input('Have you resolved conflicts? (y/n): ').trim_space().to_lower()
					if ans == 'y' || ans == 'yes' {
						continue_res := exec_git_cmd(['git', 'rebase', '--continue'])
						if continue_res.exit_code == 0 {
							resolved = true
							break
						} else {
							println('Error: Failed to continue rebase:')
							println(continue_res.output.trim_space())
						}
					} else {
						break
					}
				}
				if !resolved {
					println('Aborting rebase...')
					exec_git_cmd(['git', 'rebase', '--abort'])
					return
				}
			} else {
				println('Conflicts resolved automatically in favor of newer changes.')
			}
		}
		println('Pushing updated history to remote (${force_flag})...')
		if !push_to_remote(formatted_url, branch, force_flag, false) {
			return
		}
		println('Successfully removed commit ${commit_sha} from remote.')
		return
	}
	if positional_args[1] == 'over' {
		if positional_args.len < 5 {
			print_usage()
			return
		}
		git_url := positional_args[2]
		commit_msg := positional_args[3]
		file_path := positional_args[4]
		repo_dir, rel_path := get_repo_and_relative_path(file_path)
		os.chdir(repo_dir) or {
			println('Error: Invalid path.')
			return
		}
		defer { os.chdir(original_wd) or {} }
		mut branch := 'main'
		if branch_override != '' {
			branch = branch_override
		} else {
			branch = get_current_branch()
		}
		changed_files := get_gitless_changed_files(repo_dir, rel_path, git_url, token,
			branch, lazy_push)
		mut filtered_files := []string{}
		if changed_files.len > 0 {
			filtered_files = validate_and_filter_files(changed_files) or { return }
		}
		if filtered_files.len == 0 {
			println('No file changes detected compared to remote. Proceeding with history overwrite (force push) anyway...')
		} else {
			if !confirm_upload(filtered_files, auto_confirm) {
				println('Push canceled.')
				return
			}
		}
		println('\nWarning: The "over" command will completely overwrite the remote history on branch "${branch}".')
		if !auto_confirm {
			ans := os.input('Are you sure you want to proceed with overwriting the remote history? (y/n): ').trim_space().to_lower()
			if ans != 'y' && ans != 'yes' {
				println('Push canceled.')
				return
			}
		}
		formatted_url := format_git_url(git_url, token)
		mut created_temp_git := false
		if !is_git_repo(repo_dir) {
			delete_git_dir(repo_dir)
			println('Initializing temporary local repository for commit/push...')
			if !run_git_cmd(['git', 'init'], 'Failed to initialize repository') {
				return
			}
			if !run_git_cmd(['git', 'checkout', '-b', branch], 'Failed to set branch') {
				created_temp_git = true
			}
		} else {
			if branch_override != '' {
				if !run_git_cmd(['git', 'checkout', '-B', branch], 'Failed to checkout branch') {
					return
				}
			}
		}
		defer {
			if created_temp_git {
				println('Cleaning up temporary local .git directory...')
				delete_git_dir(repo_dir)
			}
		}
		mut files_to_add := []string{}
		mut files_to_rm := []string{}
		for file in filtered_files {
			if os.exists(file) {
				files_to_add << file
			} else {
				files_to_rm << file
			}
		}
		if files_to_add.len > 0 {
			git_add_files(files_to_add)
		}
		if !lazy_push && files_to_rm.len > 0 {
			git_rm_files(files_to_rm)
		}
		println('Committing changes...')
		has_staged_changes := exec_git_cmd(['git', 'diff', '--cached', '--quiet']).exit_code != 0
		commits := get_commit_list(branch)
		if commits.len > 0 {
			println('Overwriting the previous commit (Amending)...')
			if !run_git_cmd(['git', 'commit', '--amend', '-m', commit_msg], 'Failed to amend commit') {
				return
			}
		} else {
			if has_staged_changes {
				if !run_git_cmd(['git', 'commit', '-m', commit_msg], 'Failed to commit') {
					return
				}
			} else {
				println('No local unstaged changes to commit. Proceeding with force push...')
			}
		}
		println('Overwriting remote history (${force_flag})...')
		if !push_to_remote(formatted_url, branch, force_flag, true) {
			return
		}
		println('Successfully force-pushed changes.')
		return
	}
	if positional_args.len == 4 {
		git_url := positional_args[1]
		commit_msg := positional_args[2]
		file_path := positional_args[3]
		repo_dir, rel_path := get_repo_and_relative_path(file_path)
		os.chdir(repo_dir) or {
			println('Error: Invalid path.')
			return
		}
		defer { os.chdir(original_wd) or {} }
		mut branch := 'main'
		if branch_override != '' {
			branch = branch_override
		} else {
			branch = get_current_branch()
		}
		changed_files := get_gitless_changed_files(repo_dir, rel_path, git_url, token,
			branch, lazy_push)
		mut filtered_files := []string{}
		if changed_files.len > 0 {
			filtered_files = validate_and_filter_files(changed_files) or { return }
		}
		if filtered_files.len == 0 {
			println('All changed files were excluded or no changes detected. Nothing to upload.')
			return
		}
		if !confirm_upload(filtered_files, auto_confirm) {
			println('Push canceled.')
			return
		}
		formatted_url := format_git_url(git_url, token)
		mut created_temp_git := false
		defer {
			if created_temp_git {
				println('Cleaning up temporary local .git directory...')
				delete_git_dir(repo_dir)
			}
		}
		if !is_git_repo(repo_dir) {
			delete_git_dir(repo_dir)
			println('Initializing temporary local repository for commit/push...')
			if !run_git_cmd(['git', 'init'], 'Failed to initialize repository') {
				return
			}
			if !run_git_cmd(['git', 'symbolic-ref', 'HEAD', 'refs/heads/' + branch], 'Failed to set target branch') {
				return
			}
			if !run_git_cmd(['git', 'remote', 'add', 'origin', formatted_url], 'Failed to add remote origin') {
				return
			}
			println('Fetching remote branch history...')
			fetch_res := exec_git_cmd(['git', 'fetch', '--depth', '1', 'origin', '${branch}:refs/remotes/origin/${branch}'])
			if fetch_res.exit_code == 0 {
				if !run_git_cmd(['git', 'reset', 'origin/' + branch], 'Failed to sync with remote history') {
					return
				}
			}
			created_temp_git = true
		} else {
			if branch_override != '' {
				if !run_git_cmd(['git', 'checkout', '-B', branch], 'Failed to checkout branch') {
					return
				}
			}
			println('Checking if remote branch exists...')
			ls_res := exec_git_cmd(['git', 'ls-remote', '--heads', formatted_url, branch])
			mut remote_exists := false
			if ls_res.exit_code == 0 && ls_res.output.trim_space() != '' {
				remote_exists = true
			}
			if remote_exists {
				println('Auto-syncing (pulling) with remote repository...')
				has_changes_to_stash := exec_git_cmd(['git', 'status', '--porcelain']).output.trim_space() != ''
				mut stashed := false
				if has_changes_to_stash {
					stash_res := exec_git_cmd(['git', 'stash', '-u'])
					if stash_res.exit_code == 0 && !stash_res.output.contains('No local changes to save') {
						stashed = true
					}
				}
				pull_res := exec_git_cmd(['git', 'pull', formatted_url, branch, '--rebase'])
				if stashed {
					exec_git_cmd(['git', 'stash', 'pop'])
				}
				if pull_res.exit_code != 0 {
					println('Error: Auto-sync (pull) failed. This usually happens if there are merge conflicts.')
					println('Details: ' + pull_res.output.trim_space())
					println('Aborting sync...')
					exec_git_cmd(['git', 'rebase', '--abort'])
					println('Sync aborted. Please pull manually or use the "over" command to overwrite remote history.')
					return
				}
			} else {
				println('Remote branch "${branch}" not found (likely empty repository). Skipping pull.')
			}
		}
		mut files_to_add := []string{}
		mut files_to_rm := []string{}
		for file in filtered_files {
			if os.exists(file) {
				files_to_add << file
			} else {
				files_to_rm << file
			}
		}
		if files_to_add.len > 0 {
			git_add_files(files_to_add)
		}
		if !lazy_push && files_to_rm.len > 0 {
			git_rm_files(files_to_rm)
		}
		println('Committing changes...')
		has_staged_changes := exec_git_cmd(['git', 'diff', '--cached', '--quiet']).exit_code != 0
		if has_staged_changes {
			if !run_git_cmd(['git', 'commit', '-m', commit_msg], 'Failed to commit') {
				return
			}
		} else {
			println('No local unstaged changes to commit. Proceeding with push...')
		}
		println('Pushing to remote...')
		if !push_to_remote(formatted_url, branch, '', false) {
			return
		}
		println('Successfully pushed changes.')
		return
	}
	if positional_args.len == 3 {
		git_url := positional_args[1]
		file_path := positional_args[2]
		repo_dir, rel_path := get_repo_and_relative_path(file_path)
		os.chdir(repo_dir) or {
			println('Error: Invalid path.')
			return
		}
		defer { os.chdir(original_wd) or {} }
		if !is_git_repo(repo_dir) {
			println('Error: No git repository found to amend.')
			return
		}
		mut branch := 'main'
		if branch_override != '' {
			branch = branch_override
		} else {
			branch = get_current_branch()
		}
		changed_files := get_gitless_changed_files(repo_dir, rel_path, git_url, token,
			branch, lazy_push)
		mut filtered_files := []string{}
		if changed_files.len > 0 {
			filtered_files = validate_and_filter_files(changed_files) or { return }
		}
		if filtered_files.len == 0 {
			println('No file changes detected compared to remote. Proceeding with amending history anyway...')
		} else {
			if !confirm_upload(filtered_files, auto_confirm) {
				println('Push canceled.')
				return
			}
		}
		commit_info := get_commit_info('HEAD')
		println('\nWarning: This action will amend and overwrite the last commit on the remote branch "${branch}":')
		println(' -> ${commit_info}')
		if !auto_confirm {
			ans := os.input('Do you want to proceed with amending and force-pushing? (y/n): ').trim_space().to_lower()
			if ans != 'y' && ans != 'yes' {
				println('Push canceled.')
				return
			}
		}
		formatted_url := format_git_url(git_url, token)
		mut files_to_add := []string{}
		mut files_to_rm := []string{}
		for file in filtered_files {
			if os.exists(file) {
				files_to_add << file
			} else {
				files_to_rm << file
			}
		}
		if files_to_add.len > 0 {
			git_add_files(files_to_add)
		}
		if !lazy_push && files_to_rm.len > 0 {
			git_rm_files(files_to_rm)
		}
		println('Amending last commit...')
		if !run_git_cmd(['git', 'commit', '--amend', '--no-edit'], 'Failed to amend commit') {
			return
		}
		println('Force pushing updated commit to remote (${force_flag})...')
		if !push_to_remote(formatted_url, branch, force_flag, true) {
			return
		}
		println('Successfully amended last commit and force pushed.')
		return
	}
	print_usage()
}
