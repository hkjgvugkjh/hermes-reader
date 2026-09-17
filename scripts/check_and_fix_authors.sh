#!/bin/bash
# 检查每个目录的提交者，将所有非 hkjgvugkjh 的提交者改为 hkjgvugkjh
# 使用方法: ./check_and_fix_authors.sh

REPO_PATH="/home/william/.hermes/workspace/github/hermes-reader"
TARGET_NAME="hkjgvugkjh"
TARGET_EMAIL="hkjgvugkjh@users.noreply.github.com"

cd "$REPO_PATH" || exit 1

echo "=== 开始检查每个目录的提交者 ==="
echo "目标作者: $TARGET_NAME <$TARGET_EMAIL>"
echo ""

# 获取所有目录（排除 .git）
dirs=$(find . -type d -not -path "./.git/*" -not -path "./.git" | sort)

changed=0
unchanged=0

for dir in $dirs; do
    # 检查该目录是否有提交记录
    commits=$(git log --format="%an <%ae>" --all -- "$dir" 2>/dev/null | sort | uniq -c | sort -rn)
    
    if [ -n "$commits" ]; then
        # 检查是否有非 hkjgvugkjh 的提交者
        non_target=$(echo "$commits" | grep -v "$TARGET_NAME" | grep -v "^ *[0-9]* $TARGET_NAME")
        
        if [ -n "$non_target" ]; then
            echo "目录: $dir"
            echo "  当前提交者:"
            echo "$commits" | sed 's/^/    /'
            echo "  -> 需要修改为 $TARGET_NAME"
            
            # 使用 git filter-branch 修改提交者
            rm -rf .git/refs/original/
            FILTER_BRANCH_SQUELCH_WARNING=1 git filter-branch --force --env-filter "
            if [ \"\$GIT_AUTHOR_NAME\" != \"$TARGET_NAME\" ] || [ \"\$GIT_AUTHOR_EMAIL\" != \"$TARGET_EMAIL\" ]; then
                export GIT_AUTHOR_NAME=\"$TARGET_NAME\"
                export GIT_AUTHOR_EMAIL=\"$TARGET_EMAIL\"
            fi
            if [ \"\$GIT_COMMITTER_NAME\" != \"$TARGET_NAME\" ] || [ \"\$GIT_COMMITTER_EMAIL\" != \"$TARGET_EMAIL\" ]; then
                export GIT_COMMITTER_NAME=\"$TARGET_NAME\"
                export GIT_COMMITTER_EMAIL=\"$TARGET_EMAIL\"
            fi
            " -- --all 2>&1 | grep -E "(Rewrite|Ref)" | sed 's/^/    /'
            
            changed=$((changed + 1))
            echo ""
        else
            unchanged=$((unchanged + 1))
        fi
    fi
done

echo "=== 检查完成 ==="
echo "需要修改的目录: $changed"
echo "无需修改的目录: $unchanged"
echo ""
echo "请执行以下命令推送更改:"
echo "  git push --force origin master"
