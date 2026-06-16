-- Filter: only pass through object recognition records with confidence >= threshold
function pred(record)
    local objResult = record.ObjectRecognitionResult
    if objResult == nil then
        return false
    end
    local identity = objResult.IdentityData
    if identity == nil then
        return false
    end
    local confidence = tonumber(identity.confidence) or 0
    return confidence >= 55
end
