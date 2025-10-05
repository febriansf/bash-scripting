#!/bin/bash

set -a
source .env
set +a

# Temporary fix HDSentinel running issue whie in crontab :D
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

BOT_TOKEN=$BOT_TOKEN
CHAT_ID=$CHAT_ID
XML_FILE="/tmp/report.xml"  
HDSENTINEL_PATH=$SENTINEL_PATH
SERVER_NAME="Server-Hostname"

check_dependencies() {
    local dependencies=("xmlstarlet" "curl")
    for dep in "${dependencies[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            echo "$dep is not installed. Please install it!."
            exit 1
        fi
    done

    if [ ! -f "$HDSENTINEL_PATH" ]; then
        echo "HDSentinel not found at $HDSENTINEL_PATH"
        exit 1
    fi
}

generate_report() {
    echo "Generating XML report..."
    if ! "$HDSENTINEL_PATH" -xml -r "$XML_FILE" > /dev/null; then
        echo "Failed to generate XML report"
        exit 1
    fi
    echo "XML report generated at $XML_FILE"
}

send_to_telegram() {
    local MESSAGE="$1"
    curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        -d "chat_id=$CHAT_ID" \
        -d "text=$MESSAGE" \
        -d "parse_mode=Markdown" >/dev/null
}

disk_num_check() {
    local indices=()
    local max_attempts=10  
    for ((i=0; i<max_attempts; i++)); do
        local disk_path="//Physical_Disk_Information_Disk_${i}/Hard_Disk_Summary/Hard_Disk_Number"
        local disk_exists=$(xmlstarlet sel -t -v "$disk_path" "$XML_FILE" 2>/dev/null)

        if [ -n "$disk_exists" ]; then
            indices+=("$i")
        fi
    done
    echo "${indices[@]}"
}

main() {
    check_dependencies
    
    generate_report
    
    DATE_TIME=$(xmlstarlet sel -t -v "//Current_Date_And_Time" "$XML_FILE" 2>/dev/null)
    UPTIME=$(xmlstarlet sel -t -v "//Uptime" "$XML_FILE" 2>/dev/null)
    MESSAGE="
        \[Disk-Report]

        🕒 *Date and Time:* $DATE_TIME
        💻 *Server:* [$SERVER_NAME]
        ⏳ *Uptime:* $UPTIME
    "
    ress_disk=($(disk_num_check))
    if [ ${#ress_disk[@]} -eq 0 ]; then
        MESSAGE+="⚠️ *No Disks Detected* ⚠️"
        send_to_telegram "$MESSAGE"
        echo "$MESSAGE"
        exit 1
    fi
    for DISK_INDEX in "${ress_disk[@]}"; do
        DISK_PATH="//Physical_Disk_Information_Disk_${DISK_INDEX}/Hard_Disk_Summary"
        HDD_NUMBER=$(xmlstarlet sel -t -v "$DISK_PATH/Hard_Disk_Number" "$XML_FILE" 2>/dev/null)
        DEVICE=$(xmlstarlet sel -t -v "$DISK_PATH/Hard_Disk_Device" "$XML_FILE" 2>/dev/null)
        MODEL_ID=$(xmlstarlet sel -t -v "$DISK_PATH/Hard_Disk_Model_ID" "$XML_FILE" 2>/dev/null)
        SERIAL_NUMBER=$(xmlstarlet sel -t -v "$DISK_PATH/Hard_Disk_Serial_Number" "$XML_FILE" 2>/dev/null)
        TOTAL_SIZE=$(xmlstarlet sel -t -v "$DISK_PATH/Total_Size" "$XML_FILE" 2>/dev/null)
        CURRENT_TEMP=$(xmlstarlet sel -t -v "$DISK_PATH/Current_Temperature" "$XML_FILE" 2>/dev/null)
        MAX_TEMP=$(xmlstarlet sel -t -v "$DISK_PATH/Maximum_temperature_during_entire_lifespan" "$XML_FILE" 2>/dev/null)
        POWER_ON_TIME=$(xmlstarlet sel -t -v "$DISK_PATH/Power_on_time" "$XML_FILE" 2>/dev/null)
        REMAINING_LIFETIME=$(xmlstarlet sel -t -v "$DISK_PATH/Estimated_remaining_lifetime" "$XML_FILE" 2>/dev/null)
        HEALTH=$(xmlstarlet sel -t -v "$DISK_PATH/Health" "$XML_FILE" 2>/dev/null)
        PERFORMANCE=$(xmlstarlet sel -t -v "$DISK_PATH/Performance" "$XML_FILE" 2>/dev/null)
        TOTAL_WRITTEN=$(xmlstarlet sel -t -v "$DISK_PATH/Lifetime_writes" "$XML_FILE" 2>/dev/null)
        DESCRIPTION=$(xmlstarlet sel -t -v "$DISK_PATH/Description" "$XML_FILE" 2>/dev/null)
        
        if [[ "$MODEL" == *Virtual* || "$MODEL" == *Floppy* ]]; then
            continue
        fi

        if [[ "$SERIAL" == "?" || "$SIZE" == "0 MB" ]]; then
            continue
        fi

        if [[ "$HEALTH" == "? %" || "$PERFORMANCE" == "? %" ]]; then
            continue
        fi

        
        MESSAGE+="
            - *Disk_Number $HDD_NUMBER*
            - *Device:* $DEVICE
            - *Model:* $MODEL_ID
            - *Serial Number:* $SERIAL_NUMBER
            - *Current Temp:* $CURRENT_TEMP
            - *Max Temp:* $MAX_TEMP
            - *Power On Time:* $POWER_ON_TIME
            - *Remaining Lifetime:* $REMAINING_LIFETIME
            - *Health:* $HEALTH
            - *Performance:* $PERFORMANCE
            - *Total Written:* $TOTAL_WRITTEN
            - *Description:* $DESCRIPTION

            "
    done
    send_to_telegram "$MESSAGE"
    rm -f "$XML_FILE"
    echo "Message sent to Telegram!"
}

main