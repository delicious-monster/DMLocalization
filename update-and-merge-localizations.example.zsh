#!/bin/zsh

set -e

if [ ! -n "${SRCROOT+isset}" ]; then
    # Running in as shell script in UberLibrary/Library
    export SRCROOT=$(dirname $0)
    # (/om[1]) selects most recently-modified directory
    BUILD_BASE_LPROJ=$(echo ~/Library/Developer/Xcode/DerivedData/UberLibrary-*/Build/Products/*/"Delicious Library 3.app"/Contents/Resources/Base.lproj(/om[1]))
    test -d ${BUILD_BASE_LPROJ} || ( echo "Build directory not found" >&2 ; exit 1 )
else
    BUILD_BASE_LPROJ=${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/Base.lproj
fi

test -d ${SRCROOT} || ( echo "SRCROOT ${SRCROOT} not directory" >&2 ; exit 1 )

# this is what xcodebuild happens to use
TOOL_BUILD_DIR=~/Library/Developer/Xcode/DerivedData/Debug


function phase() {
    echo "==== $@ ====" >&2
}


phase "Create temporary directory for Example.lproj"
TEMP_EXAMPLE_LPROJ=$(mktemp -d -t Example.lproj)


phase "Internationalize ObjC into ${TEMP_EXAMPLE_LPROJ:t}"
# -q silences duplicate comments with same key warning
genstrings -q -o ${TEMP_EXAMPLE_LPROJ} ${SRCROOT}/../(Library|Shared|GoldenBraeburnStore)/**/*.[hm]


phase "Internationalize Charts into ${TEMP_EXAMPLE_LPROJ:t}"
# -q silences duplicate comments with same key warning
# in these files "Charts.strings" is the table specified
genstrings -q -o ${TEMP_EXAMPLE_LPROJ} -s jsLocalizedString ${SRCROOT}/"Charts HTML"/*.{js,html}


phase "Build xibLocalizationPostprocessor"
xcodebuild -project ${SRCROOT}/../Vendor/DMLocalization/DMLocalization.xcodeproj -target xibLocalizationPostprocessor -configuration Debug SYMROOT=${TOOL_BUILD_DIR:h} >/dev/null

phase "Internationalize Target Base.lproj/ .xib, strings, .plist files into ${TEMP_EXAMPLE_LPROJ:t}"
foreach pathInBase (${BUILD_BASE_LPROJ}/*(.))
    if [[ ${pathInBase} == *.nib ]] {
        nibBasename=`basename ${pathInBase} .nib`
        xibFilePath=`echo ${SRCROOT}/../(Shared|Library)/**/${nibBasename}.xib(.N)`
        if [[ -e ${xibFilePath} ]] {
            stringsFilePath=${TEMP_EXAMPLE_LPROJ}/${nibBasename}.strings
            (ibtool --generate-stringsfile ${stringsFilePath} ${xibFilePath} ;
             ${TOOL_BUILD_DIR}/xibLocalizationPostprocessor ${stringsFilePath}) &
            let index+=1
            pids[index]=$!
        } else {
            echo "ERROR: can't find matching source XIB for NIB ${nibBasename}.nib" >&2
        }
    } else {
       cp ${pathInBase} ${TEMP_EXAMPLE_LPROJ}
    }
end
foreach pid (${pids})
    wait ${pid} 2> /dev/null || true
end


phase "Move strings to source directory"
rm -f ${SRCROOT}/Example.lproj/*(.)
mv -f ${TEMP_EXAMPLE_LPROJ}/*(.) ${SRCROOT}/Example.lproj/
rm -rf ${TEMP_EXAMPLE_LPROJ}


phase "Build mergeLocalizations"
xcodebuild -project ${SRCROOT}/../Vendor/DMLocalization/DMLocalization.xcodeproj -target mergeLocalizations -configuration Debug SYMROOT=${TOOL_BUILD_DIR:h} >/dev/null

phase "Merge Localizations"
${TOOL_BUILD_DIR}/mergeLocalizations


phase "Check Localization Plists"
# -s: don't print anything on success
/usr/bin/plutil -lint -s ${SRCROOT}/*.lproj/*.strings(.N)
