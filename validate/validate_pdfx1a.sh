#!/bin/bash

if [ -z "$1" ]; then
    echo "Usage: $0 <path_to_pdf_file>"
    exit 1
fi

TARGET_PDF="$1"

if [ ! -f "$TARGET_PDF" ]; then
    echo -e "\e[31mError: File '$TARGET_PDF' not found.\e[0m"
    exit 1
fi

# Ensure prerequisite tools are available
if ! command -v pdfinfo &> /dev/null || ! command -v pdfimages &> /dev/null || ! command -v pdffonts &> /dev/null; then
    echo -e "\e[31mError: Missing poppler-utils. Run: sudo apt install poppler-utils\e[0m"
    exit 1
fi

FAILED=0
WARNINGS=()

echo "=================================================================="
echo "              CHECKING FOR STRICT PDF/X-1a COMPLIANCE             "
echo "=================================================================="


# 1. Enforce Strict Base Specification PDF Version 1.3
echo -n "Checking PDF Version is 1.3............."
PDF_VERSION=$(pdfinfo "$TARGET_PDF" 2>/dev/null | grep "PDF version:" | awk '{print $3}')
if [ "$PDF_VERSION" = "1.3" ]; then
    echo -e "\e[32m[PASS]\e[0m"
else
    echo -e "\e[31m[FAIL]\e[0m (PDF is v$PDF_VERSION)"
    FAILED=1
fi

# 2. Check Metadata Header
echo -n "Checking PDF/X Metadata Header.........."
PDFX_META=$(pdfinfo -meta "$TARGET_PDF" 2>/dev/null | grep -i "pdf/x")
if [ -n "$PDFX_META" ]; then
    echo -e "\e[32m[PASS]\e[0m"
else
    echo -e "\e[31m[FAIL]\e[0m (Missing PDF/X declaration)"
    FAILED=1
fi


# 3. Check for Embedded Output Intent Color Profile
echo -n "Checking Embedded Output Intent........."
OUTPUT_INTENT=$(grep -a -o '/OutputIntent' "$TARGET_PDF" 2>/dev/null | wc -l)
if [ "$OUTPUT_INTENT" -gt 0 ]; then
    echo -e "\e[32m[PASS]\e[0m"
else
    echo -e "\e[31m[FAIL]\e[0m (No target print profile/ICC embedded)"
    FAILED=1
fi


#4. Check for Font Asset Embedding
echo -n "Checking Font Asset Embedding..........."
UNEMBEDDED=$(pdffonts "$TARGET_PDF" 2>/dev/null | awk 'NR>2 {print $5}' | grep -i 'no' | wc -l)
if [ "$UNEMBEDDED" -eq 0 ]; then
    echo -e "\e[32m[PASS]\e[0m"
else
    echo -e "\e[31m[FAIL]\e[0m ($UNEMBEDDED missing fonts)"
    FAILED=1
fi


# 5. Check Geometry Boxes (TrimBox / BleedBox Presence)
echo -n "Checking Print Box Specifications......."
BOX_INFO=$(pdfinfo -box "$TARGET_PDF" 2>/dev/null)
HAS_TRIM=$(echo "$BOX_INFO" | grep -i "TrimBox")
HAS_BLEED=$(echo "$BOX_INFO" | grep -i "BleedBox")

if [ -n "$HAS_TRIM" ] && [ -n "$HAS_BLEED" ]; then
    echo -e "\e[32m[PASS]\e[0m"
else
    echo -e "\e[31m[FAIL]\e[0m (Missing trim/bleed boxes)"
    FAILED=1
fi


# 6. Check Vector Color Spaces
echo -n "Scanning for Prohibited RGB Vectors....."
RGB_STREAMS=$(grep -a -o '/DeviceRGB' "$TARGET_PDF" 2>/dev/null | wc -l)
if [ "$RGB_STREAMS" -eq 0 ]; then
    echo -e "\e[32m[PASS]\e[0m"
else
    echo -e "\e[31m[FAIL]\e[0m ($RGB_STREAMS instances found)"
    FAILED=1
fi


# 7. Check Raster Color Spaces
echo -n "Scanning for Prohibited RGB Images......"
RGB_IMAGES=$(pdfimages -list "$TARGET_PDF" 2>/dev/null | awk 'NR>2 {print $4}' | grep -E -i 'rgb|lab' | wc -l)
if [ "$RGB_IMAGES" -eq 0 ]; then
    echo -e "\e[32m[PASS]\e[0m"
else
    echo -e "\e[31m[FAIL]\e[0m ($RGB_IMAGES RGB images found)"
    FAILED=1
fi


# 8. Check for Prohibited Transparencies
echo -n "Scanning for Prohibited Transparency...."
# /Group /Transparency and /ExtGState are checked for alpha/transparency parameters
TRANSPARENCY_HOOKS=$(grep -a -E '/Transparency|/Group.*/Transparent|/BM.*/Transparent' "$TARGET_PDF" 2>/dev/null | wc -l)
if [ "$TRANSPARENCY_HOOKS" -eq 0 ]; then
    echo -e "\e[32m[PASS]\e[0m"
else
    echo -e "\e[31m[FAIL]\e[0m ($TRANSPARENCY_HOOKS transparent objects detected)"
    FAILED=1
fi


# 8. Check for Interactive Links (Prohibited in PDF/X-1a)
echo -n "Scanning for Prohibited Links..........."
LINKS=$(grep -a -o '/Link' "$TARGET_PDF" 2>/dev/null | wc -l)
if [ "$LINKS" -eq 0 ]; then
    echo -e "\e[32m[PASS]\e[0m"
else
    echo -e "\e[31m[FAIL]\e[0m ($LINKS links detected)"
    FAILED=1
fi


# 9. Check for Prohibited Embedded Scripts (JavaScript)
echo -n "Scanning for Prohibited JavaScript......"
JS_COUNT=$(grep -a -o '/JavaScript' "$TARGET_PDF" 2>/dev/null | wc -l)
if [ "$JS_COUNT" -eq 0 ]; then
    echo -e "\e[32m[PASS]\e[0m"
else
    echo -e "\e[31m[FAIL]\e[0m ($JS_COUNT JavaScript references)"
    FAILED=1
fi


# 10. Check for Prohibited Forms and Annotations
echo -n "Scanning for Prohibited Form Fields....."
FORM_COUNT=$(grep -a -o '/AcroForm' "$TARGET_PDF" 2>/dev/null | wc -l)
if [ "$FORM_COUNT" -eq 0 ]; then
    echo -e "\e[32m[PASS]\e[0m"
else
    echo -e "\e[31m[FAIL]\e[0m ($FORM_COUNT forms detected)"
    FAILED=1
fi


echo "=================================================================="
echo "            CHECKING QUALIITY (Non-Critical Warnings)             "
echo "=================================================================="

# 11. Asset Validation: Image Resolution & Fonts
echo -n "Checking Raster Resolution (>300DPI)...."
LOW_RES=$(pdfimages -list "$TARGET_PDF" 2>/dev/null | awk 'NR>2 {print $13}' | awk '$1 ~ /^[0-9]+$/ && $1 < 300 {count++} END {print count+0}')
if [ "$LOW_RES" -eq 0 ]; then
    echo -e "\e[32m[PASS]\e[0m"
else
    echo -e "\e[93m[WARN]\e[0m ($LOW_RES low-res images)"
    WARNINGS+=("Low Image Resolutions Found")
fi


# 12. Hairline Risk Scan (Warning Only)
echo -n "Scanning Vectors for Hairline Strokes..."
# Looks for stroke weight configurations assigned to zero or near-zero widths
HAIRLINES=$(grep -a -E '(^|\s)0(\.0+)?\s+w(\s|$)' "$TARGET_PDF" 2>/dev/null | wc -l)
if [ "$HAIRLINES" -eq 0 ]; then
    echo -e "\e[32m[PASS]\e[0m"
else
    echo -e "\e[93m[WARN]\e[0m ($HAIRLINES strokes set near 0 width)"
    WARNINGS+=("$HAIRLINES Hairline Strokes Found")
fi


# Final Summary
echo "=================================================================="
if [ "$FAILED" -gt 0 ]; then
    echo -e "\e[41m\e[37m     VERDICT: NOT PDF/X-1a COMPLIANT (Critical Errors Exist)      \e[0m"
elif [ ${#WARNINGS[@]} -gt 0 ]; then
    echo -e "\e[103m\e[30m     VERDICT: STRUCTURE COMPLIANT BUT POSSIBLE QUALITY ISSUES     \e[0m"
else
    echo -e "\e[42m\e[30m       VERDICT: EXCELLENT! 100% PDF/X-1a PRINTER COMPLIANT        \e[0m"
fi

exit $FAILED

