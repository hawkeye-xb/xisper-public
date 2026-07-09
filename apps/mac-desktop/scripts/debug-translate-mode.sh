#!/bin/bash

# Debug script for translate mode stuck issue
# Usage: ./debug-translate-mode.sh [watch|clear|export]

LOG_FILE="/tmp/xisper-crash-debug.log"
REC_LOG_FILE="/tmp/xisper-recording.log"

case "${1:-help}" in
    watch)
        echo "Watching debug logs (Ctrl+C to stop)..."
        echo "========================================"
        tail -f "$LOG_FILE" "$REC_LOG_FILE" 2>/dev/null
        ;;
    
    clear)
        echo "Clearing log files..."
        rm -f "$LOG_FILE" "$REC_LOG_FILE"
        echo "✅ Logs cleared"
        ;;
    
    export)
        EXPORT_DIR="$HOME/Desktop/xisper-debug-$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$EXPORT_DIR"
        
        if [ -f "$LOG_FILE" ]; then
            cp "$LOG_FILE" "$EXPORT_DIR/crash-debug.log"
        fi
        
        if [ -f "$REC_LOG_FILE" ]; then
            cp "$REC_LOG_FILE" "$EXPORT_DIR/recording.log"
        fi
        
        # Export system info
        cat > "$EXPORT_DIR/system-info.txt" <<EOF
macOS Version: $(sw_vers -productVersion)
Build: $(sw_vers -buildVersion)
Timestamp: $(date)
EOF
        
        echo "✅ Debug logs exported to: $EXPORT_DIR"
        open "$EXPORT_DIR"
        ;;
    
    grep)
        if [ -z "$2" ]; then
            echo "Usage: $0 grep <pattern>"
            exit 1
        fi
        echo "Searching for: $2"
        echo "========================================"
        grep -i "$2" "$LOG_FILE" "$REC_LOG_FILE" 2>/dev/null
        ;;
    
    analyze)
        echo "Analyzing logs for translate mode issues..."
        echo "========================================"
        echo ""
        
        echo "1. Upgrade events:"
        grep "UPGRADE" "$LOG_FILE" 2>/dev/null | tail -10
        echo ""
        
        echo "2. commitUp mismatches:"
        grep "commitUp MISMATCH" "$LOG_FILE" 2>/dev/null | tail -10
        echo ""
        
        echo "3. currentActionId at handleKeyPress (should be nil):"
        grep "handleKeyPress.*currentActionId=" "$LOG_FILE" 2>/dev/null | grep -v "nil" | tail -10
        echo ""
        
        echo "4. Translate mode activations:"
        grep "isTranslateMode=true" "$LOG_FILE" 2>/dev/null | tail -10
        echo ""
        
        echo "5. currentActionId clearing:"
        grep "clearing currentActionId" "$LOG_FILE" 2>/dev/null | tail -10
        ;;
    
    help|*)
        cat <<EOF
Debug script for translate mode stuck issue

Usage: $0 <command>

Commands:
  watch     - Watch debug logs in real-time
  clear     - Clear all log files
  export    - Export logs to Desktop with timestamp
  grep      - Search for pattern in logs
  analyze   - Analyze logs for common issues
  help      - Show this help message

Log files:
  - $LOG_FILE
  - $REC_LOG_FILE

Example workflow:
  1. ./debug-translate-mode.sh clear
  2. Run the app and reproduce the issue
  3. ./debug-translate-mode.sh analyze
  4. ./debug-translate-mode.sh export

EOF
        ;;
esac
