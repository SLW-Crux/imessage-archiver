#!/bin/bash
# Audit every place iMessage data could live on this Mac.
# Prints sizes and file counts so you can see where 29 GB might be —
# or confirm it's not on this Mac at all.

set -u

declare -a LOCATIONS=(
    # The canonical chat.db + Attachments
    "$HOME/Library/Messages"
    "$HOME/Library/Messages/Attachments"

    # Mac MobileSMS sandbox (some attachments cache here)
    "$HOME/Library/Containers/com.apple.MobileSMS"
    "$HOME/Library/Group Containers/group.com.apple.messages"

    # Messages app caches
    "$HOME/Library/Caches/com.apple.Messages"
    "$HOME/Library/Caches/com.apple.MobileSMS"

    # CloudKit local mirror — this is where Messages-in-iCloud
    # data would live IF macOS were caching it locally
    "$HOME/Library/Application Support/CloudKit"
    "$HOME/Library/Application Support/IMServiceAgent"
    "$HOME/Library/Application Support/com.apple.sharedfilelist"

    # Other iMessage / FaceTime support
    "$HOME/Library/Application Support/FaceTime"
    "$HOME/Library/Application Support/MobileSync"

    # Photos / cache of attachments
    "$HOME/Library/Group Containers/group.com.apple.MobileSMS"
)

total_bytes=0
printf "%-65s %12s %10s\n" "PATH" "SIZE" "FILES"
printf "%-65s %12s %10s\n" "-----------------------------------------------------------------" "----" "-----"

for path in "${LOCATIONS[@]}"; do
    if [ -e "$path" ]; then
        # du -sk for size in KB; find for file count
        size_kb=$(du -sk "$path" 2>/dev/null | awk '{print $1}')
        size_h=$(du -sh "$path" 2>/dev/null | awk '{print $1}')
        files=$(find "$path" -type f 2>/dev/null | wc -l | tr -d ' ')
        # Truncate path for display
        display="$path"
        if [ ${#display} -gt 63 ]; then
            display="...${display: -60}"
        fi
        printf "%-65s %12s %10s\n" "$display" "$size_h" "$files"
        total_bytes=$((total_bytes + size_kb))
    else
        printf "%-65s %12s %10s\n" "$path" "(absent)" "-"
    fi
done

echo ""
total_gb=$(echo "scale=2; $total_bytes / 1024 / 1024" | bc)
echo "Total across all iMessage locations: ${total_gb} GB"
echo ""
echo "--- For reference ---"
echo "iCloud Settings reports:       29 GB"
echo "If our total is well below 29 GB, the difference is on Apple's iCloud"
echo "servers in their private CloudKit container — not on this Mac."
echo ""
echo "--- chat.db only ---"
ls -lh ~/Library/Messages/chat.db 2>&1 | awk '{print $5, $9}'
echo "Local attachment file count:"
find ~/Library/Messages/Attachments -type f 2>/dev/null | wc -l | tr -d ' '
echo ""
echo "--- counts from chat.db ---"
echo "Total messages:        $(sqlite3 -readonly ~/Library/Messages/chat.db 'SELECT COUNT(*) FROM message' 2>/dev/null)"
echo "Total chats:           $(sqlite3 -readonly ~/Library/Messages/chat.db 'SELECT COUNT(*) FROM chat' 2>/dev/null)"
echo "Total attachment rows: $(sqlite3 -readonly ~/Library/Messages/chat.db 'SELECT COUNT(*) FROM attachment' 2>/dev/null)"
echo "Cloud-tracked rows:    $(sqlite3 -readonly ~/Library/Messages/chat.db 'SELECT COUNT(*) FROM attachment WHERE ck_record_id IS NOT NULL' 2>/dev/null)"
