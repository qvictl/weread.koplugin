package.path = "./?.lua;" .. package.path
package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end }
end

local Annotations = require("weread.lib.annotations")
local External = require("weread.lib.external_annotations")
local checks = 0
local function expect(value, message)
    checks = checks + 1
    assert(value, message)
end

-- Include a function sentinel: KOReader's JSON codec may represent null this
-- way. Scalars must not stop conversion or hide the valid neighbouring item.
local malformed = { false, true, 7, "invalid", function() end }
for _, value in ipairs(malformed) do
    expect(#Annotations.buildThoughtPopupItems(value) == 0, "invalid range review was accepted")
    expect(#Annotations.buildThoughtPopupItems({ pageReviews = value }) == 0,
        "invalid page-review list was accepted")
    local items = Annotations.buildThoughtPopupItems({ pageReviews = {
        value, { review = value },
        { review = { abstract = "quote", content = "first", author = value }, likesCount = "4" },
        { review = { abstract = "not repeated", content = "second", author = { name = "Reader" } } },
    } })
    expect(#items == 2, "malformed records discarded valid thoughts or produced blank items")
    expect(items[1].abstract == "quote" and items[1].content == "first"
        and items[1].author == "匿名" and items[1].likes_count == 4,
        "first valid thought lost its abstract, content or fallback author")
    expect(items[2].abstract == nil and items[2].content == "second" and items[2].author == "Reader",
        "later valid thought changed")
    local reviews = { value, { range = "1-2", pageReviews = {
        value, { review = value }, { review = { abstract = " quote " } },
    } } }
    expect(External.quote_for({ range = "1-2" }, reviews) == "quote",
        "quote lookup failed to skip malformed page reviews")
    expect(External.quote_for({ range = "1-2", markText = "original" }, reviews) == "original",
        "review fallback overrode the underline quote")
    expect(External.quote_for({ range = "1-2" }, { { range = "1-2", pageReviews = value } }) == "",
        "invalid page-review list supplied a quote")
end
expect(#Annotations.buildThoughtPopupItems({}) == 0, "missing pages were accepted")
expect(#Annotations.buildThoughtPopupItems({ pageReviews = {} }) == 0, "empty pages were not empty")
local items = Annotations.buildThoughtPopupItems({ pageReviews = {
    {}, { review = { abstract = "", contextAbstract = "", content = 42, author = { nick = "Nick" } } },
} })
expect(#items == 1 and items[1].abstract == nil and items[1].content == "42"
    and items[1].author == "Nick" and items[1].likes_count == 0,
    "missing review or ordinary field fallbacks changed")
expect(External.quote_for({ range = "1-2" }, { { range = "1-2", pageReviews = {
    {}, { contextAbstract = "legacy direct quote" },
} } }) == "legacy direct quote", "direct legacy quote fallback was lost")
expect(External.quote_for({ range = "1-2" }, { { range = "1-2", pageReviews = {
    { review = {} }, false,
} } }) == "", "all-empty/malformed pages supplied a quote")
expect(External.quote_for(false, {}) == "", "invalid underline supplied a quote")
expect(External.quote_for({ range = "missing" }, {}) == "", "missing review supplied a quote")
for _, value in ipairs({ "", false, 42, {}, function() end }) do
    local recovered = Annotations.buildThoughtPopupItems({ pageReviews = {
        false, { review = { abstract = value, contextAbstract = "context quote", content = "thought" } },
    } })
    expect(#recovered == 1 and recovered[1].abstract == "context quote",
        "unusable abstract masked the first valid thought's context abstract")
end
for _, value in ipairs({ "", " \t\r\n", false, {}, function() end }) do
    local review = { range = "1-2", pageReviews = { { review = {
        abstract = value, contextAbstract = " context quote ", markText = "mark quote",
    } } } }
    expect(External.quote_for({ range = "1-2" }, { review }) == "context quote",
        "unclean abstract masked a usable context quote")
    review.pageReviews[1].review.contextAbstract = " \t"
    expect(External.quote_for({ range = "1-2" }, { review }) == "mark quote",
        "empty cleaned abstract/context masked the mark-text fallback")
end
print(("annotation_payload_spec: %d checks"):format(checks))
