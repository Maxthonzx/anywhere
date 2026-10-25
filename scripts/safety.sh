#!/usr/bin/env bash
# Shared safety checks. Source this file; never print matching secret values.
# Bash 3.2 / Git Bash, Git only. This is a heuristic guard, not a secret audit.
SENSITIVE_PATTERN='(gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN (RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----|https?://[^ /:@]+:[^ /@]+@)'

# Reject empty values, option-like strings, multiple lines, http(s) userinfo,
# and any scheme with user:password. ssh://user@host/path has no password and is allowed.
url_embeds_credentials() {
  case "$1" in
    ''|-*|*$'\n'*|*://*:*@*|http://*@*|https://*@*) return 0 ;;
  esac
  return 1
}

sensitive_path() {
  local base="${1##*/}" prev=0 result=1
  # Bash 3.2 has no ${var,,}. nocasematch avoids `tr` and command-substitution
  # stripping, which would let a trailing newline hide a sensitive name.
  shopt -q nocasematch && prev=1
  shopt -s nocasematch
  case "$base" in
    .env.example) result=1 ;;
    .env|.env.*|*.env|.envrc|*.pem|*.key|*.p12|*.pfx|id_rsa|id_dsa|id_ed25519|id_ecdsa|credentials.json|.netrc|.npmrc|.pypirc) result=0 ;;
  esac
  if [ "$prev" -eq 1 ]; then shopt -s nocasematch; else shopt -u nocasematch; fi
  return "$result"
}

# Check a complete candidate tree, including already tracked sensitive files.
check_tree() {
  local tree="$1" entry meta f mode size failed=0 result
  git ls-tree -r -z "$tree" > "$TMP/tree-entries" || return 1
  while IFS= read -r -d '' entry; do
    meta="${entry%%$'\t'*}"
    f="${entry#*$'\t'}"
    mode="${meta%% *}"
    case "$mode" in
      160000)
        # Not a blob. cat-file -s fails here and used to be reported as a
        # credential hit. Refuse the gitlink instead of deleting it: git add -A
        # treats a missing submodule checkout as a deletion.
        printf '子模块不在支持范围内 / Submodule gitlink is not supported: %q\n' "$f" >&2
        failed=1
        continue
        ;;
      100644|100755|120000) ;;
      *)
        printf '不支持的 Git 条目 / Unsupported Git entry: %q (%s)\n' "$f" "$mode" >&2
        failed=1
        continue
        ;;
    esac
    if sensitive_path "$f"; then
      printf '拒绝同步敏感文件 / Sensitive file: %q\n' "$f" >&2
      failed=1
    fi
    size="$(git cat-file -s "$tree:$f")" || {
      echo '无法读取对象大小 / Cannot read object size.' >&2
      return 1
    }
    if [ "$size" -gt "$MAX_BYTES" ]; then
      printf '文件超过大小上限 / File too large: %q (%s bytes)\n' "$f" "$size" >&2
      failed=1
    fi
  done < "$TMP/tree-entries"
  # --quiet avoids putting credential values (or malicious filenames) in logs.
  git grep -I -q -E -e "$SENSITIVE_PATTERN" "$tree" --
  result=$?
  if [ "$result" -eq 0 ]; then
    echo '发现疑似凭据 / Possible credential detected; inspect locally, remove and rotate it.' >&2
    failed=1
  elif [ "$result" -ne 1 ]; then
    echo '凭据检查失败 / Credential check failed.' >&2
    failed=1
  fi
  return "$failed"
}

check_text() {
  local result
  # Consume all input: grep -q could hide a match behind SIGPIPE with pipefail.
  LC_ALL=C grep -E "$SENSITIVE_PATTERN" >/dev/null
  result=$?
  if [ "$result" -eq 0 ]; then
    echo '提交或标签文本中发现疑似凭据 / Possible credential in commit or tag text; inspect and rotate locally.' >&2
    return 1
  fi
  [ "$result" -eq 1 ]
}

check_commit() {
  check_tree "$1" || return 1
  # %B is only the message. Author, committer and other headers can carry a token too.
  git cat-file commit "$1" | check_text
}
