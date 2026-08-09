#!/bin/bash

echo "🧪 Arvos Platform Quick Test"
echo "============================"
echo ""

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test 1: Check dependencies
echo "1️⃣  Checking dependencies..."
if command -v node >/dev/null 2>&1; then
    echo -e "${GREEN}✅ Node.js found:${NC} $(node --version)"
else
    echo -e "${RED}❌ Node.js not found${NC}"
    exit 1
fi

if command -v python3 >/dev/null 2>&1; then
    echo -e "${GREEN}✅ Python3 found:${NC} $(python3 --version)"
else
    echo -e "${RED}❌ Python3 not found${NC}"
    exit 1
fi

if command -v xcodebuild >/dev/null 2>&1; then
    echo -e "${GREEN}✅ Xcode found:${NC} $(xcodebuild -version | head -1)"
else
    echo -e "${RED}❌ Xcode not found${NC}"
    exit 1
fi

echo ""

# Test 2: Check ports
echo "2️⃣  Checking ports availability..."
if lsof -i :3000 >/dev/null 2>&1; then
    echo -e "${YELLOW}⚠️  Port 3000 is in use (Next.js)${NC}"
else
    echo -e "${GREEN}✅ Port 3000 available${NC}"
fi

if lsof -i :8765 >/dev/null 2>&1; then
    echo -e "${YELLOW}⚠️  Port 8765 is in use (WebSocket)${NC}"
else
    echo -e "${GREEN}✅ Port 8765 available${NC}"
fi

echo ""

# Test 3: Check project structure
echo "3️⃣  Checking project structure..."
if [ -d "/Users/jaskiratsingh/Desktop/arvos" ]; then
    echo -e "${GREEN}✅ iOS app directory found${NC}"
else
    echo -e "${RED}❌ iOS app directory not found${NC}"
    exit 1
fi

if [ -d "/Users/jaskiratsingh/Desktop/Arvos-web" ]; then
    echo -e "${GREEN}✅ Web Studio directory found${NC}"
else
    echo -e "${RED}❌ Web Studio directory not found${NC}"
    exit 1
fi

if [ -d "/Users/jaskiratsingh/Desktop/arvos-sdk" ]; then
    echo -e "${GREEN}✅ Python SDK directory found${NC}"
else
    echo -e "${RED}❌ Python SDK directory not found${NC}"
    exit 1
fi

echo ""

# Test 4: Check Web Studio dependencies
echo "4️⃣  Checking Web Studio setup..."
if [ -d "/Users/jaskiratsingh/Desktop/Arvos-web/node_modules" ]; then
    echo -e "${GREEN}✅ Web Studio dependencies installed${NC}"
else
    echo -e "${YELLOW}⚠️  Web Studio dependencies not installed${NC}"
    echo "   Run: cd /Users/jaskiratsingh/Desktop/Arvos-web && npm install"
fi

echo ""

# Test 5: Get network info
echo "5️⃣  Network information..."
echo "Your Mac's IP addresses:"
ifconfig | grep "inet " | grep -v 127.0.0.1 | awk '{print "   " $2}'

echo ""

# Test 6: Check critical fix
echo "6️⃣  Verifying critical bug fix..."
if grep -q "if isServerMode {" /Users/jaskiratsingh/Desktop/arvos/arvos/Managers/NetworkManager.swift; then
    echo -e "${GREEN}✅ Server mode broadcasting fix applied${NC}"
else
    echo -e "${RED}❌ Server mode broadcasting fix NOT applied${NC}"
    echo "   This fix is critical for camera/depth streaming!"
fi

echo ""
echo "============================"
echo ""
echo -e "${GREEN}🎉 Setup verification complete!${NC}"
echo ""
echo "📚 Next steps:"
echo "   1. Read: /Users/jaskiratsingh/Desktop/arvos/COMPLETE_TESTING_GUIDE.md"
echo "   2. Start Web Studio: cd Arvos-web && npm run dev"
echo "   3. Open iOS app in Xcode and run"
echo "   4. Connect and test streaming"
echo ""
