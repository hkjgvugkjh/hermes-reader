#!/bin/bash
# 在远程服务器(32)上运行的脚本：将所有目录的提交者统一改为 hkjgvugkjh
# 使用方法: ssh william@10.10.164.32 "bash -s" < fix_all_authors_remote.sh

set -e

REPO_PATH="/home/william/.hermes/workspace/github/hermes-reader"
TARGET_NAME="hkjgvugkjh"
TARGET_EMAIL="hkjgvugkjh@users.noreply.github.com"

cd "$REPO_PATH" || { echo "错误: 无法进入 $REPO_PATH"; exit 1; }

echo "=== 统一所有目录的提交者为 $TARGET_NAME <$TARGET_EMAIL> ==="
echo "仓库路径: $REPO_PATH"
echo ""

# 先获取当前所有不同的提交者
echo "当前所有提交者:"
git log --format="%an <%ae>" --all | sort | uniq -c | sort -rn
echo ""

# 执行 filter-branch 修改所有提交的 author 和 committer
echo "正在重写历史..."
rm -rf .git/refs/original/
FILTER_BRANCH_SQUELCH_WARNING=1 git filter-branch --force --env-filter "
OLD_NAMES=\"tomac HowToLoveChina\"
OLD_EMAILS=\"5379823@qq.com\"

# 检查 author
for old in \$OLD_NAMES; do
    if [ \"\$GIT_AUTHOR_NAME\" = \"\$old\" ]; then
        export GIT_AUTHOR_NAME=\"$TARGET_NAME\"
        export GIT_AUTHOR_EMAIL=\"$TARGET_EMAIL\"
        break
    fi
done
for old in \$OLD_EMAILS; do
    if [ \"\$GIT_AUTHOR_EMAIL\" = \"\$old\" ]; then
        export GIT_AUTHOR_NAME=\"$TARGET_NAME\"
        export GIT_AUTHOR_EMAIL=\"$TARGET_EMAIL\"
        break
    fi
done

# 检查 committer
for old in \$OLD_NAMES; do
    if [ \"\$GIT_COMMITTER_NAME\" = \"\$old\" ]; then
        export GIT_COMMITTER_NAME=\"$TARGET_NAME\"
        export GIT_COMMITTER_EMAIL=\"$TARGET_EMAIL\"
        break
    fi
done
for old in \$OLD_EMAILS; do
    if [ \"\$GIT_COMMITTER_EMAIL\" = \"\$old\" ]; then
        export GIT_COMMITTER_NAME=\"$TARGET_NAME\"
        export GIT_COMMITTER_EMAIL=\"$TARGET_EMAIL\"
        break
    fi
done
" -- --all 2>&1 | grep -E "(Rewrite|Ref|WARNING)" | head -20

echo ""
echo "=== 验证结果 ==="
echo "修改后的所有提交者:"
git log --format="%an <%ae>" --all | sort | uniq -c | sort -rn
echo ""

# 强制推送到 GitHub
echo "正在推送到 GitHub..."
git -c http.proxy=socks5h://10.10.164.50:31288 -c https.proxy=socks5h://10.10.164.50:31288 push --force origin master

echo ""
echo "=== 完成 ==="