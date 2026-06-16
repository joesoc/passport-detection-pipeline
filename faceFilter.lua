-- Filter: return true if a face was detected in the record
-- This filter track gates object recognition to only run on frames with faces

function pred(record)
    -- Check that FaceData exists (face was detected)
    if record.FaceData == nil then
        return false
    end

    -- Optionally filter for frontal faces only
    -- Uncomment below to restrict to forward-facing faces:
    -- local oopangle = record.FaceData.outofplaneanglex
    -- if oopangle == 90 or oopangle == -90 then return false end

    -- Optionally filter by face size (percentage of image)
    -- Uncomment below to restrict to faces filling a minimum portion of the frame:
    -- if record.FaceData.percentageinimage < 5 then return false end

    return true
end
