#!/bin/bash

echo "🔍 Arvos Connection Debug"
echo "========================"
echo ""

# Get the iPhone IP from user
read -p "Enter iPhone IP (from app): " IPHONE_IP

echo ""
echo "1️⃣ Checking your Mac's network..."
echo "Your Mac's IP addresses:"
ifconfig | grep "inet " | grep -v 127.0.0.1 | awk '{print "   " $2}'

echo ""
echo "2️⃣ Testing if iPhone is reachable..."
if ping -c 2 -t 2 $IPHONE_IP >/dev/null 2>&1; then
    echo "✅ iPhone is reachable at $IPHONE_IP"
else
    echo "❌ Cannot reach iPhone at $IPHONE_IP"
    echo ""
    echo "Possible issues:"
    echo "  • iPhone and Mac not on same WiFi network"
    echo "  • Wrong IP address"
    echo "  • Firewall blocking ping"
    echo ""
    echo "Make sure both devices show same WiFi name in settings!"
    exit 1
fi

echo ""
echo "3️⃣ Testing WebSocket server on iPhone..."
if nc -zv -w 2 $IPHONE_IP 8765 2>&1 | grep -q "succeeded"; then
    echo "✅ WebSocket server is running on $IPHONE_IP:8765"
else
    echo "❌ WebSocket server NOT accessible on $IPHONE_IP:8765"
    echo ""
    echo "Make sure:"
    echo "  • iOS app is running"
    echo "  • You tapped 'START STREAMING' button"
    echo "  • App shows the server is running"
    echo ""
    exit 1
fi

echo ""
echo "4️⃣ Testing WebSocket connection..."
# Try to connect with a simple test
(echo -e "GET / HTTP/1.1\r\nHost: $IPHONE_IP\r\n\r\n"; sleep 1) | nc $IPHONE_IP 8765 > /tmp/ws-test.txt 2>&1

if [ -s /tmp/ws-test.txt ]; then
    echo "✅ Got response from server!"
    echo "First line:"
    head -1 /tmp/ws-test.txt
else
    echo "⚠️  No response from server (might be normal for WS)"
fi

echo ""
echo "========================"
echo "✅ Connection test complete!"
echo ""
echo "If all checks passed, try connecting from Web Studio again."
echo "Web Studio URL: http://localhost:3000/studio"
echo "iPhone IP: $IPHONE_IP"
echo "Port: 8765"
