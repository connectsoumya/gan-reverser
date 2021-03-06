require 'torch'
require 'image'
require 'paths'
require 'pl' -- this is somehow responsible for lapp working in qlua mode
require 'optim'
require 'unsup'
ok, DISP = pcall(require, 'display')
if not ok then print('display not found. unable to plot') end
DATASET = require 'dataset'
NN_UTILS = require 'utils.nn_utils'
MODELS = require 'models'

OPT = lapp[[
    --batchSize     (default 32)
    --seed          (default 1)
    --gpu           (default 0)
    --threads       (default 8)            Number of threads
    --G             (default "logs/adversarial.net")
    --R             (default "logs/r_3x32x32_nd32_normal.net")
    --R_fixer       (default "logs/r_3x32x32_nd32_normal_fixer.net")
    --dataset       (default "NONE")       Directory that contains *.jpg images
    --writeTo       (default "r_results")  Directory in which to save images
]]

NORMALIZE = false
START_TIME = os.time()

if OPT.gpu < 0 or OPT.gpu > 3 then OPT.gpu = false end
print(OPT)

-- fix seed
math.randomseed(OPT.seed)
torch.manualSeed(OPT.seed)

-- threads
torch.setnumthreads(OPT.threads)
print('<torch> set nb of threads to ' .. torch.getnumthreads())

-- possible output of disciminator
CLASSES = {"0", "1"}
Y_GENERATOR = 0
Y_NOT_GENERATOR = 1

-- run on gpu if chosen
-- We have to load all kinds of libraries here, otherwise we risk crashes when loading
-- saved networks afterwards
print("starting gpu support...")
require 'nn'
require 'cutorch'
require 'cunn'
require 'dpnn'
if OPT.gpu then
    cutorch.setDevice(OPT.gpu + 1)
    cutorch.manualSeed(OPT.seed)
    print(string.format("using gpu device %d", OPT.gpu))
end
torch.setdefaulttensortype('torch.FloatTensor')

function main()
    -- load G
    print(string.format("loading trained G from file '%s'", OPT.G))
    local tmp = torch.load(OPT.G)
    MODEL_G = tmp.G
    MODEL_G:evaluate()
    OPT.noiseDim = tmp.opt.noiseDim
    OPT.noiseMethod = tmp.opt.noiseMethod
    OPT.height = tmp.opt.height
    OPT.width = tmp.opt.width
    OPT.colorSpace = tmp.opt.colorSpace

    ----------------------------------------------------------------------
    -- set stuff dependent on height, width and colorSpace
    ----------------------------------------------------------------------
    -- axis of images: 3 channels, <scale> height, <scale> width
    if OPT.colorSpace == "y" then
        IMG_DIMENSIONS = {1, OPT.height, OPT.width}
    else
        IMG_DIMENSIONS = {3, OPT.height, OPT.width}
    end

    -- get/create dataset
    assert(OPT.dataset ~= "NONE")
    DATASET.setColorSpace(OPT.colorSpace)
    DATASET.setFileExtension("jpg")
    DATASET.setHeight(IMG_DIMENSIONS[2])
    DATASET.setWidth(IMG_DIMENSIONS[3])
    DATASET.setDirs({OPT.dataset})
    ----------------------------------------------------------------------

    -- Load R
    print(string.format("loading trained R from file '%s'", OPT.R))
    local tmp = torch.load(OPT.R)
    MODEL_R = tmp.R
    MODEL_R:evaluate()

    -- Load R fixer
    if OPT.R_fixer == "" then
        MODEL_R_FIXER = MODEL_R
    else
        print(string.format("loading trained R-fixer from file '%s'", OPT.R_fixer))
        local tmp = torch.load(OPT.R_fixer)
        MODEL_R_FIXER = tmp.R
        MODEL_R_FIXER:evaluate()
    end

    if OPT.gpu == false then
        MODEL_G:float()
        MODEL_R:float()
    end

    -------------------------------------------
    -- Vary single components (one by one) of a noise vector
    -- Gives intuition about the embedding learned by G
    -------------------------------------------
    print("Varying components...")
    local nbSteps = 16
    local steps
    if OPT.noiseMethod == "uniform" then
        steps = torch.linspace(-1, 1, nbSteps)
    else
        steps = torch.linspace(-3, 3, nbSteps)
    end
    local noise = NN_UTILS.createNoiseInputs(1)
    --local face = MODEL_G:forward(NN_UTILS.createNoiseInputs(1)):clone()
    --face = face[1]

    noise = torch.repeatTensor(noise[1], OPT.noiseDim*nbSteps, 1)
    --local variations = torch.Tensor(OPT.noiseDim*10, IMG_DIMENSIONS[1], IMG_DIMENSIONS[2], IMG_DIMENSIONS[3])
    local imgIdx = 1
    for i=1,OPT.noiseDim do
        for j=1,nbSteps do
            noise[imgIdx][i] = steps[j]
            imgIdx = imgIdx + 1
        end
    end
    local variations = NN_UTILS.forwardBatched(MODEL_G, noise, OPT.batchSize):clone()
    variations = image.toDisplayTensor{input=variations, nrow=nbSteps, min=0, max=1.0}
    image.save(paths.concat(OPT.writeTo, 'variations.jpg'), variations)

    -------------------------------------------
    -- Generate example images for all later steps
    -------------------------------------------
    print("Generating images...")
    --local images = DATASET.loadImages(1, 50000)
    local noise = NN_UTILS.createNoiseInputs(10000)
    local images = NN_UTILS.forwardBatched(MODEL_G, noise, OPT.batchSize)

    -------------------------------------------
    -- Recover noise vectors of example images using R
    -------------------------------------------
    print("Converting images to attributes...")
    local attributes = NN_UTILS.forwardBatched(MODEL_R, images, OPT.batchSize)
    local attributesFixer = NN_UTILS.forwardBatched(MODEL_R_FIXER, images, OPT.batchSize)

    -------------------------------------------
    -- Cluster the generated images into 20 clusters
    -------------------------------------------
    print("Clustering...")
    local nbClusters = 20
    local nbIterations = 15
    local nbMaxPerCluster = 64+7
    local filenamePattern = 'cluster_%02d.jpg'
    createClusterImages(nbClusters, nbIterations, nbMaxPerCluster, images, attributes, filenamePattern)

    -------------------------------------------
    -- Pick faces, search for most similar ones
    -- (similarity based on the recovered noise vectors)
    -------------------------------------------
    print("Finding faces by similarity...")
    local nbSimilarNeedles = 5
    local nbShowMax = 100
    createSimilaritySearchImages(nbSimilarNeedles, nbShowMax, images, attributes)

    -------------------------------------------
    -- Fix images generated by G
    -- Fix is done via
    --   noise -> G -> image -> R -> noise -> G -> image
    -------------------------------------------
    print("Fixing faces...")
    local nbPairs = 52
    local nbFixedImages = 512+16
    fixFaces(nbPairs, nbFixedImages, images, attributesFixer)

    -------------------------------------------
    -- Detect anomalies
    -------------------------------------------
    print("Detecting anomalies...")
    local nbImagesCalculations = 1024
    local nbImagesShow = 512+16
    local threshold = 0.15
    detectAnomalies(nbImagesCalculations, nbImagesShow, threshold, images, noise, attributesFixer)
end

-- Group all images into clusters based on their recovered noise
-- vectors (cosine similarity) using kmeans. The generated cluster images
-- are saved according to parameter filenamePattern.
function createClusterImages(nbClusters, nbIterations, nbMaxPerCluster, images, attributes, filenamePattern)
    local centroids, counts = unsup.kmeans(attributes, nbClusters, nbIterations)
    local img2cluster = {} -- maps imageIdx => clusterIdx
    local cluster2imgs = {} -- maps clusterIdx => [(image, distance), (image, distance), ...]
    for i=1,nbClusters do
        table.insert(cluster2imgs, {})
    end

    -- find best clusters for each face
    for i=1,attributes:size(1) do
        local minDist = nil
        local minDistCluster = nil
        for j=1,nbClusters do
            local dist = cosineSimilarity(attributes[i], centroids[j])
            if minDist == nil or dist < minDist then
                minDist = dist
                minDistCluster = j
            end
        end
        img2cluster[i] = minDistCluster
        table.insert(cluster2imgs[minDistCluster], {images[i], minDist})
    end

    -- restrict each cluster to the N images closest to its centroid
    -- also sort images by their distance to the centroid
    for i=1,nbClusters do
        local clusterImgs = cluster2imgs[i]
        table.sort(clusterImgs, function(a,b) return a[2]>b[2] end)

        local closestClusterImgs = {}
        for i=1,math.min(nbMaxPerCluster, #clusterImgs) do
            table.insert(closestClusterImgs, clusterImgs[i])
        end
        cluster2imgs[i] = closestClusterImgs
    end

    -- generate the average of all faces in a cluster (for each cluster)
    local averageFaces = {}
    for i=1,nbClusters do
        local clusterImgs = cluster2imgs[i]
        local face = torch.zeros(IMG_DIMENSIONS[1], IMG_DIMENSIONS[2], IMG_DIMENSIONS[3])
        for j=1,#clusterImgs do
            face:add(clusterImgs[j][1])
        end
        face:div(#clusterImgs)
        table.insert(averageFaces, face)
    end

    -- merge faces within a cluster to one image and save it (for each cluster)
    print("Save images of clusters...")
    for i=1,nbClusters do
        local clusterImgs = cluster2imgs[i]
        if #clusterImgs > 0 then
            local tnsr = torch.zeros(1 + #clusterImgs, IMG_DIMENSIONS[1], IMG_DIMENSIONS[2], IMG_DIMENSIONS[3])
            tnsr[1] = averageFaces[i]
            for j=1,#clusterImgs do
                tnsr[1+j] = clusterImgs[j][1]
            end
            tnsr = NN_UTILS.toRgb(tnsr, OPT.colorSpace)
            tnsr = image.toDisplayTensor{input=tnsr, nrow=math.ceil(math.sqrt(tnsr:size(1))), min=0, max=1.0}
            image.save(paths.concat(OPT.writeTo, string.format(filenamePattern, i)), tnsr)
        end
    end
end

-- Find images by similarity to example images
-- Compare via (1) cosine similarity based on recovered noise vectors and
-- (2) cosine similarity based on the generated face images
function createSimilaritySearchImages(nbSimilarNeedles, nbShowMax, images, attributes)
    function createImages(similarityMeasure, filenamePattern)
        for i=1,nbSimilarNeedles do
            local face_i_idx = i*100
            local similar = {}
            for j=1,attributes:size(1) do
                --table.insert(similar, {j, torch.dist(atts, attributes[j])})
                local sim = similarityMeasure(face_i_idx, j)
                table.insert(similar, {j, sim})
            end
            table.sort(similar, function(a,b) return a[2]>b[2] end)
            --print(similar)

            local n = math.min(nbShowMax, #similar)
            local tnsr = torch.Tensor(n, IMG_DIMENSIONS[1], IMG_DIMENSIONS[2], IMG_DIMENSIONS[3])
            for j=1,n do
                tnsr[j] = images[similar[j][1]]
            end

            tnsr = NN_UTILS.toRgb(tnsr, OPT.colorSpace)

            -- add blue border around search image
            tnsr[{{1}, {3}, {1,IMG_DIMENSIONS[2]}, {1}}] = 1.0 -- left
            tnsr[{{1}, {3}, {1,IMG_DIMENSIONS[2]}, {IMG_DIMENSIONS[3]}}] = 1.0 -- right
            tnsr[{{1}, {3}, {1}, {1,IMG_DIMENSIONS[3]}}] = 1.0 -- top
            tnsr[{{1}, {3}, {IMG_DIMENSIONS[2]}, {1,IMG_DIMENSIONS[3]}}] = 1.0 -- bottom

            tnsr[{{1}, {1,2}, {1,IMG_DIMENSIONS[2]}, {1}}] = 0.0 -- left
            tnsr[{{1}, {1,2}, {1,IMG_DIMENSIONS[2]}, {IMG_DIMENSIONS[3]}}] = 0.0 -- right
            tnsr[{{1}, {1,2}, {1}, {1,IMG_DIMENSIONS[3]}}] = 0.0 -- top
            tnsr[{{1}, {1,2}, {IMG_DIMENSIONS[2]}, {1,IMG_DIMENSIONS[3]}}] = 0.0 -- bottom

            tnsr = image.toDisplayTensor{input=tnsr, nrow=math.ceil(math.sqrt(tnsr:size(1))), min=0, max=1.0}
            image.save(paths.concat(OPT.writeTo, string.format(filenamePattern, i)), tnsr)
        end
    end

    -- compare faces with indices i and j using their recovered noise vectors (R)
    local similarityMeasureAttributes = function (face_i, face_j)
        return cosineSimilarity(attributes[face_i], attributes[face_j])
    end

    -- compare faces with indices i and j using their generated images (G)
    local similarityMeasurePixelwise = function (face_i, face_j)
        local face_i = images[face_i]:clone()
        face_i = face_i:view(face_i:nElement())
        local face_j = images[face_j]:clone()
        face_j = face_j:view(face_j:nElement())
        return cosineSimilarity(face_i, face_j)
    end

    createImages(similarityMeasureAttributes, "similar_attributes_%02d.jpg")
    createImages(similarityMeasurePixelwise, "similar_pixelwise_%02d.jpg")
end

-- Test fixing of faces using R. Generates three images:
-- (1) Pairs of unfixed and fixed faces next to each other
-- (2) One big image with the first N faces, unfixed
-- (3) One big image with the first N faces, fixed
function fixFaces(nbPairs, nbFixedImages, images, attributesFixer)
    local pairs = torch.zeros(nbPairs, 3, 1+IMG_DIMENSIONS[2]+1, 1 + 2*IMG_DIMENSIONS[3] + 1) -- N pairs, 2 images, 1px borders around pairs
    pairs[{{}, {3}, {}, {}}] = 1.0 -- blue background

    for i=1,nbPairs do
        local afterG = images[i]:clone() -- face
        local afterGR = NN_UTILS.toBatch(attributesFixer[i]) -- noise vector recovered by R
        afterGR = afterGR:repeatTensor(2, 1) -- for whatever reason torch insists on getting 2 instead of 1 vector
        local afterGRG = MODEL_G:forward(afterGR):clone()[1] -- fixed face (G->R->G)

        afterG = NN_UTILS.toRgbSingle(afterG, OPT.colorSpace)
        afterGRG = NN_UTILS.toRgbSingle(afterGRG, OPT.colorSpace)

        pairs[{{i}, {}, {2, 1+IMG_DIMENSIONS[2]}, {2, 1+IMG_DIMENSIONS[3]}}] = afterG
        pairs[{{i}, {}, {2, 1+IMG_DIMENSIONS[2]}, {1+IMG_DIMENSIONS[3]+1, 1+IMG_DIMENSIONS[3]+IMG_DIMENSIONS[3]}}] = afterGRG
    end

    pairs = image.toDisplayTensor{input=pairs, nrow=4, min=0, max=1.0}
    image.save(paths.concat(OPT.writeTo, 'fixed_pairs.jpg'), pairs)

    -- Create one big image of fixed faces (also save the unfixed faces)
    local unfixedImages = images[{{1,nbFixedImages}, {}, {}, {}}]:clone()
    unfixedImages = image.toDisplayTensor{input=unfixedImages, nrow=math.floor(math.sqrt(nbFixedImages)), min=0, max=1.0}
    image.save(paths.concat(OPT.writeTo, string.format('fixed_images_%d_unfixed.jpg', nbFixedImages)), unfixedImages)

    local fixedImages = NN_UTILS.forwardBatched(MODEL_G, attributesFixer[{{1,nbFixedImages}, {}}], OPT.batchSize)
    fixedImages = image.toDisplayTensor{input=fixedImages, nrow=math.floor(math.sqrt(nbFixedImages)), min=0, max=1.0}
    image.save(paths.concat(OPT.writeTo, string.format('fixed_images_%d.jpg', nbFixedImages)), fixedImages)
end

-- Find anomalous images among N generated images
function detectAnomalies(nbImagesCalculations, nbImagesShow, threshold, images, noise, attributesFixer)
    -- collect similarity scores
    -- distances here are really similarities, ie (1-distance)
    local distancesForSort = {} -- used to find the threshold of the x% most dissimilar images
    local distances = {}
    for i=1,nbImagesCalculations do
        local batch = torch.zeros(2, attributesFixer:size(2))
        batch[1] = attributesFixer[i]
        local fixedImage = MODEL_G:forward(batch):clone()[1]
        -- distance is based on euclidian distance between originally generated
        -- image and fixed image
        local dist = 1 - torch.dist(images[i], fixedImage)
        table.insert(distancesForSort, dist)
        table.insert(distances, dist)
    end

    table.sort(distancesForSort)
    local anomalyBelow = distancesForSort[math.floor(#distancesForSort*threshold)]

    -- collect images to show, mark anomalies
    local anomalyImages = torch.zeros(nbImagesShow, 3, 1+IMG_DIMENSIONS[2]+1, 1+IMG_DIMENSIONS[3]+1)
    for i=1,nbImagesShow do
        local dist = distances[i]
        local isAnomaly = (dist <= anomalyBelow)

        -- red border for anomalies
        if isAnomaly then
            anomalyImages[{{i}, {1}, {1,IMG_DIMENSIONS[2]+2}, {1,IMG_DIMENSIONS[3]+2}}] = 1.0
        end

        anomalyImages[{{i}, {1,3}, {2,IMG_DIMENSIONS[2]+1}, {2,IMG_DIMENSIONS[3]+1}}] = NN_UTILS.toRgbSingle(images[i], OPT.colorSpace)
    end

    anomalyImages = image.toDisplayTensor{input=anomalyImages, nrow=math.floor(math.sqrt(nbImagesShow)), min=0, max=1.0}
    image.save(paths.concat(OPT.writeTo, 'anomalies.jpg'), anomalyImages)
end

-- Measure the cosine similarity of two vectors.
-- @param v1 First vector
-- @param v2 Second vector
-- @returns float (-1.0 to +1.0)
function cosineSimilarity(v1, v2)
    local cos = nn.CosineDistance()
    local result = cos:forward({v1:clone(), v2:clone()}):clone()
    return result[1]
end

-------
main()
