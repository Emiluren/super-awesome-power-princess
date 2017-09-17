{-# LANGUAGE OverloadedStrings, RecursiveDo, ScopedTypeVariables, GADTs, TemplateHaskell #-}
module Main where

import Control.Lens ((^.))
import Control.Monad (unless, replicateM_)
import Control.Monad.Identity
import Control.Monad.IO.Class (MonadIO, liftIO)

import Data.Dependent.Map (DMap)
import qualified Data.Dependent.Map as DMap
import Data.Dependent.Sum ((==>))
import Data.Fixed (div')
import Data.GADT.Compare.TH
import Data.IORef (newIORef, modifyIORef', readIORef)
import Data.Map ((!), Map)
import qualified Data.Map as Map
import Data.StateVar (($=), get)
import Data.Word (Word32)

import Foreign.C.String (CString, withCString, peekCString)
import Foreign.C.Types (CInt, CDouble(..))
import Foreign.Marshal.Alloc (free)
import Foreign.Ptr (Ptr, castPtr, freeHaskellFunPtr)
import Foreign.StablePtr
    ( newStablePtr
    , deRefStablePtr
    , castStablePtrToPtr
    , castPtrToStablePtr
    , freeStablePtr
    )
import Foreign.Storable

import Linear (V2(..), V4(..))

import qualified Physics.Hipmunk as H

import Reflex
import Reflex.Host.Class
    ( newEventWithTriggerRef
    , runHostFrame
    , fireEventRef
    , fireEventRefAndRead
    , subscribeEvent
    )

import SDL (Point(P))
import qualified SDL
import qualified SDL.Image
import qualified SDL.Primitive as SDL

import qualified SpriterTypes as Spriter
import qualified SpriterBindings as Spriter

winWidth, winHeight :: Num a => a
winWidth = 800
winHeight = 600

winSize :: V2 CInt
winSize = V2 winWidth winHeight

timeStep :: Double
timeStep = 1/60

shelfStart, shelfEnd :: Num a => (a, a)
shelfStart = (100, 200)
shelfEnd = (400, 300)

makeHVector :: (Double, Double) -> H.Vector
makeHVector = uncurry H.Vector

makeSdlPoint :: Num a => (a, a) -> SDL.Point V2 a
makeSdlPoint = SDL.P . uncurry SDL.V2

startV, endV :: H.Vector
(startV, endV) = (makeHVector shelfStart, makeHVector shelfEnd)

startP, endP :: SDL.Point V2 CInt
(startP, endP) = (makeSdlPoint shelfStart, makeSdlPoint shelfEnd)

circleMass, circleRadius :: Num a => a
circleMass = 10
circleRadius = 20

initSDL :: IO SDL.Renderer
initSDL = do
    SDL.initializeAll

    let windowSettings = SDL.defaultWindow
            { SDL.windowInitialSize = winSize
            , SDL.windowResizable = True
            }
    window <- SDL.createWindow "Ava" windowSettings
    renderer <- SDL.createRenderer window (-1) SDL.defaultRenderer
    SDL.rendererScale renderer $= V2 2 2

    return renderer

loadImages :: SDL.Renderer -> [String] -> IO (Map String SDL.Texture)
loadImages renderer files =
    (Map.fromList . zip files) <$> textures
    where
        textures = mapM (SDL.Image.loadTexture renderer) files

destroyImages :: Map String SDL.Texture -> IO ()
destroyImages = mapM_ SDL.destroyTexture

textureSize :: MonadIO m => SDL.Texture -> m (V2 CInt)
textureSize texture = do
    info <- SDL.queryTexture texture
    return $ V2 (SDL.textureWidth info) (SDL.textureHeight info)

renderToPos :: MonadIO m => SDL.Renderer -> SDL.Texture -> SDL.Point V2 CInt -> Int -> m ()
renderToPos renderer texture pos frame = do
    _texSize <- textureSize texture
    let
        frameOffset = fromIntegral $ frame * 32
        sourceRect = Just $ SDL.Rectangle (P $ V2 frameOffset 0) (V2 32 32)
        destRect = Just $ SDL.Rectangle pos (V2 64 64)

    SDL.copy renderer texture sourceRect destRect

isPress :: SDL.KeyboardEventData -> Bool
isPress event =
    SDL.keyboardEventKeyMotion event == SDL.Pressed

eventKeycode :: SDL.KeyboardEventData -> SDL.Keycode
eventKeycode = SDL.keysymKeycode . SDL.keyboardEventKeysym

isKey :: SDL.Keycode -> SDL.KeyboardEventData -> Bool
isKey keycode = (== keycode) . eventKeycode

isKeyPressed :: SDL.Keycode -> SDL.Event -> Bool
isKeyPressed key event =
    case SDL.eventPayload event of
        SDL.KeyboardEvent keyboardEvent ->
            isPress keyboardEvent && isKey key keyboardEvent
        _ ->
            False

playerSpeed :: Double
playerSpeed = 500

controlVx :: Num a => a -> Bool -> Bool -> a
controlVx x True False = -x
controlVx x False True = x
controlVx _ _ _ = 0

frameTime :: Double
frameTime = 0.05

playerFrames :: Int
playerFrames = 10

playerFeetCollisionType :: Word32
playerFeetCollisionType = 1

data LogicOutput t = LogicOutput
    { playerSurfaceVel :: Behavior t H.Vector
    , playerForce :: Behavior t H.Vector
    , playerFrame :: Behavior t Int
    , playerYImpulse :: Event t Double
    , debugRenderingEnabled :: Behavior t Bool
    }

data SdlEventTag a where
    KeyEvent :: SDL.Keycode -> SdlEventTag SDL.KeyboardEventData
    OtherEvent :: SdlEventTag SDL.Event

sortEvent :: SDL.Event -> DMap SdlEventTag Identity
sortEvent event =
    case SDL.eventPayload event of
        SDL.KeyboardEvent keyboardEvent ->
            DMap.fromList [KeyEvent (eventKeycode keyboardEvent) ==> keyboardEvent]
        _ ->
            DMap.fromList [OtherEvent ==> event]

deriveGEq ''SdlEventTag
deriveGCompare ''SdlEventTag

mainReflex :: forall t m. (Reflex t, MonadHold t m, MonadFix m)
           => EventSelector t SdlEventTag
           -> Behavior t Double
           -> Event t Bool
           -> m (LogicOutput t)
mainReflex sdlEvent time ePlayerTouchGround = do
    let pressedKeyB key = hold False $ isPress <$> select sdlEvent (KeyEvent key)
        spacePressedE = ffilter isPress $ select sdlEvent (KeyEvent SDL.KeycodeSpace)
        f1PressedE = ffilter isPress $ select sdlEvent (KeyEvent SDL.KeycodeF1)

    aPressed <- pressedKeyB SDL.KeycodeA
    dPressed <- pressedKeyB SDL.KeycodeD

    playerOnGround <- hold False ePlayerTouchGround
    eDebugRendering <- mapAccum_ (\dr _ -> (not dr, not dr)) True f1PressedE
    debugRendering <- hold True eDebugRendering

    let playerAccX = controlVx playerSpeed <$> aPressed <*> dPressed
        playerAirForce = controlVx 1000 <$> aPressed <*> dPressed
        acc = H.Vector <$> playerAccX <*> pure 0
        playerAnimFrame = (\t -> floor (t / frameTime) `mod` playerFrames) <$> time

        jumpEvent = (-1500) <$ gate playerOnGround spacePressedE
        pickFirst True x _ = x
        pickFirst False _ x = x

    return LogicOutput
        { playerSurfaceVel = pickFirst <$> playerOnGround <*> acc <*> pure (H.Vector 0 0)
        , playerForce = pickFirst <$> playerOnGround <*> pure (H.Vector 0 0) <*> playerAirForce
        , playerFrame = playerAnimFrame
        , playerYImpulse = jumpEvent
        , debugRenderingEnabled = debugRendering
        }

main :: IO ()
main = do
    renderer <- initSDL
    textures <- loadImages renderer ["res/princess_running.png"]

    loadedImages <- newIORef []

    let loadImage :: CString -> CDouble -> CDouble -> IO (Ptr Spriter.Sprite)
        loadImage filename pivotX pivotY = do
            name <- peekCString filename

            tex <- SDL.Image.loadTexture renderer name
            putStrLn $ "Loaded " ++ name

            let sprite = Spriter.Sprite
                    { Spriter._spriteTexture = tex
                    , Spriter._spritePivotX = pivotX
                    , Spriter._spritePivotY = pivotY
                    , Spriter._spriteName = name
                    }

            stablePtr <- newStablePtr sprite

            modifyIORef' loadedImages (stablePtr:)
            return $ castPtr $ castStablePtrToPtr stablePtr

    imgloader <- Spriter.makeImageLoader loadImage
    renderf <- Spriter.makeRenderer $ renderSprite renderer

    Spriter.setErrorFunction
    spriterModel <- withCString "res/princess/Princess.scon"
        (Spriter.loadSpriterModel imgloader renderf)
    entityInstance <- withCString "Princess" $ Spriter.modelGetNewEntityInstance spriterModel
    withCString "Run" $ Spriter.entityInstanceSetCurrentAnimation entityInstance

    putStrLn "Initializing chipmunk"
    H.initChipmunk

    putStrLn "Creating chipmunk space"
    space <- H.newSpace
    H.gravity space $= H.Vector 0 400

    wall <- H.newBody H.infinity H.infinity
    H.position wall $= H.Vector 0 0

    let shelfShapeType = H.LineSegment startV endV 1
    shelf <- H.newShape wall shelfShapeType (H.Vector 0 0)
    H.friction shelf $= 1.0
    H.elasticity shelf $= 0.6
    H.spaceAdd space $ H.Static shelf

    let tl = H.Vector 0 0
        bl = H.Vector 0 winHeight
        tr = H.Vector winWidth 0
        br = H.Vector winWidth winHeight

        corners = [tl, bl, br, tr]
        edges = zip corners $ tail corners ++ [head corners]

    wallShapes <- forM edges $ \(start, end) -> do
        let wst = H.LineSegment start end 1
        w <- H.newShape wall wst (H.Vector 0 0)
        H.friction w $= 1.0
        H.elasticity w $= 0.6
        H.spaceAdd space $ H.Static w
        return (w, wst)

    let circleMoment = H.momentForCircle circleMass (0, circleRadius) (H.Vector 0 0)

    circleBody <- H.newBody circleMass circleMoment
    H.spaceAdd space circleBody

    let circleShapeType = H.Circle circleRadius
    circleShape <- H.newShape circleBody circleShapeType (H.Vector 0 0)
    H.friction circleShape $= 1.0
    H.elasticity circleShape $= 0.9
    H.spaceAdd space circleShape
    H.position circleBody $= H.Vector 200 20

    let makePlayerBody w h =
            [ H.Vector (-w * 0.5) (-h * 0.2)
            , H.Vector (-w * 0.5) (-h * 0.8)
            , H.Vector (-w * 0.3) (-h)
            , H.Vector (w * 0.3) (-h)
            , H.Vector (w * 0.5) (-h * 0.8)
            , H.Vector (w * 0.5) (-h * 0.2)
            , H.Vector (w * 0.3) (-h * 0.1)
            , H.Vector (-w * 0.3) (-h * 0.1)
            ]
        playerWidth = 16
        playerHeight = 56
        playerFeetShapeType = H.Circle $ playerWidth * 0.4
        playerBodyShapeType = H.Polygon $ reverse $ makePlayerBody playerWidth playerHeight
        playerMass = 5
    playerBody <- H.newBody playerMass H.infinity
    H.maxVelocity playerBody $= playerSpeed
    H.spaceAdd space playerBody
    playerFeetShape <- H.newShape playerBody playerFeetShapeType (H.Vector 0 0)
    playerBodyShape <- H.newShape playerBody playerBodyShapeType (H.Vector 0 0)
    H.spaceAdd space playerFeetShape
    H.spaceAdd space playerBodyShape
    H.friction playerFeetShape $= 2
    H.friction playerBodyShape $= 0
    H.position playerBody $= H.Vector 200 50
    H.collisionType playerFeetShape $= playerFeetCollisionType

    let
        princessTexture = textures ! "res/princess_running.png"

        render :: MonadIO m => SDL.Point V2 CInt -> Int -> Bool -> m ()
        render pos frame debugRendering = do
            SDL.rendererDrawColor renderer $= V4 50 50 50 255
            SDL.clear renderer

            renderToPos renderer princessTexture (pos - (SDL.P $ V2 32 64)) frame
            liftIO $ Spriter.renderEntityInstance entityInstance

            when debugRendering $ do
                renderShape renderer shelf shelfShapeType
                renderShape renderer circleShape circleShapeType

                forM_ wallShapes $ uncurry (renderShape renderer)

                renderShape renderer playerFeetShape playerFeetShapeType
                renderShape renderer playerBodyShape playerBodyShapeType

            SDL.present renderer

    runSpiderHost $ do
        (sdlEvent, sdlTriggerRef) <- newEventWithTriggerRef
        (eUpdateTime, eUpdateTimeTriggerRef) <- newEventWithTriggerRef
        (ePlayerGroundCollision, ePlayerGroundCollisionRef) <- newEventWithTriggerRef

        startTime <- SDL.time

        -- Create a behavior with the current time
        time <- runHostFrame $ hold startTime eUpdateTime

        logicOutput <- mainReflex (fan sdlEvent) time ePlayerGroundCollision
        jumpHandle <- subscribeEvent $ playerYImpulse logicOutput

        let playerTouchGroundCallback = do
                liftIO $ runSpiderHost $ fireEventRef ePlayerGroundCollisionRef True
                return True

            playerLeaveGroundCallback = do
                liftIO $ runSpiderHost $ fireEventRef ePlayerGroundCollisionRef False
                return ()

            playerGroundCollisionHandler = H.Handler
                { H.beginHandler = Just playerTouchGroundCallback
                , H.preSolveHandler = Nothing
                , H.postSolveHandler = Nothing
                , H.separateHandler = Just playerLeaveGroundCallback
                }

        liftIO $ H.addCollisionHandler space 0 playerFeetCollisionType playerGroundCollisionHandler

        let appLoop :: Double -> Double -> SpiderHost Global ()
            appLoop oldTime acc = do
                newTime <- SDL.time
                let dt = min (newTime - oldTime) 0.25
                    acc' = acc + dt
                    stepsToRun = acc' `div'` timeStep

                liftIO $ replicateM_ stepsToRun $ H.step space timeStep
                fireEventRef eUpdateTimeTriggerRef newTime

                events <- SDL.pollEvents
                forM_ events $ \evt -> do
                    mJump <- fireEventRefAndRead sdlTriggerRef (sortEvent evt) jumpHandle
                    case mJump of
                        Nothing -> return ()
                        Just imp -> liftIO $ H.applyImpulse playerBody (H.Vector 0 imp) (H.Vector 0 0)

                currentPlayerSurfaceVel <- runHostFrame $ sample $ playerSurfaceVel logicOutput
                currentPlayerForce <- runHostFrame $ sample $ playerForce logicOutput
                H.surfaceVel playerFeetShape $= H.scale currentPlayerSurfaceVel (-1)
                liftIO $ H.applyOnlyForce playerBody currentPlayerForce (H.Vector 0 0)

                let spriterTimeStep = CDouble $ dt * 1000
                liftIO $ Spriter.entityInstanceSetTimeElapsed entityInstance spriterTimeStep

                currentPlayerFrame <- runHostFrame $ sample $ playerFrame logicOutput
                isDebugRenderingEnabled <- runHostFrame $ sample $ debugRenderingEnabled logicOutput
                playerPos <- get $ H.position playerBody
                render (convV playerPos) currentPlayerFrame isDebugRenderingEnabled

                let qPressed = any (isKeyPressed SDL.KeycodeQ) events
                unless qPressed $ appLoop newTime $ acc' - fromIntegral stepsToRun * timeStep

        appLoop startTime 0.0

    destroyImages textures

    spriterImages <- readIORef loadedImages
    forM_ spriterImages $ \sprPtr -> do
        spr <- deRefStablePtr sprPtr
        let tex = spr ^. Spriter.spriteTexture
        SDL.destroyTexture tex
        freeStablePtr sprPtr

    SDL.quit

    free entityInstance
    free spriterModel
    freeHaskellFunPtr imgloader
    freeHaskellFunPtr renderf
    H.freeSpace space

renderSprite :: SDL.Renderer -> Spriter.Renderer
renderSprite renderer spritePtr spriteStatePtr = do
    sprite <- deRefStablePtr $ castPtrToStablePtr $ castPtr spritePtr
    spriteState <- peek spriteStatePtr

    textureInfo <- SDL.queryTexture $ sprite ^. Spriter.spriteTexture
    --putStrLn $ "rendering: " ++ sprite ^. spriteName
    --print spriteState
    -- TODO: Scale and alpha are not used, maybe switch to SFML
    let w = fromIntegral $ SDL.textureWidth textureInfo
        h = fromIntegral $ SDL.textureHeight textureInfo
        px = floor $ (sprite ^. Spriter.spritePivotX) * fromIntegral w
        py = floor $ (sprite ^. Spriter.spritePivotY) * fromIntegral h
        pivot = Just $ SDL.P $ V2 px py
        angle = spriteState ^. Spriter.spriteStateAngle
        degAngle = angle * (180/pi)
        x = floor $ spriteState^.Spriter.spriteStatePosition.Spriter.pointX + 400 - fromIntegral px
        y = floor $ spriteState^.Spriter.spriteStatePosition.Spriter.pointY + 400 - fromIntegral py
        texture = sprite ^. Spriter.spriteTexture
        renderRect = SDL.Rectangle (SDL.P $ V2 x y) (V2 w h)
    SDL.copyEx
        renderer texture Nothing (Just renderRect) (CDouble degAngle) pivot (V2 False False)

convV :: H.Vector -> SDL.Point V2 CInt
convV (H.Vector x y) = SDL.P $ V2 (floor x) (floor y)

renderShape :: MonadIO m => SDL.Renderer -> H.Shape -> H.ShapeType -> m ()
renderShape renderer shape (H.Circle radius) = do
    H.Vector px py <- get $ H.position $ H.body shape
    angle <- get $ H.angle $ H.body shape

    SDL.rendererDrawColor renderer $= V4 255 255 255 255
    let sdlPos = V2 (floor px) (floor py)
    SDL.circle renderer sdlPos (floor radius) (V4 255 255 255 255)

    let edgePoint = SDL.P $ sdlPos + V2
            (floor $ cos angle * radius)
            (floor $ sin angle * radius)
    SDL.drawLine renderer (SDL.P sdlPos) edgePoint
renderShape renderer shape (H.LineSegment p1 p2 _) = do
    pos <- get $ H.position $ H.body shape
    SDL.rendererDrawColor renderer $= V4 255 255 255 255
    SDL.drawLine renderer (convV $ p1 + pos) (convV $ p2 + pos)
renderShape renderer shape (H.Polygon verts) = do
    pos <- get $ H.position $ H.body shape
    angle <- get $ H.angle $ H.body shape
    let rot = H.rotate $ H.fromAngle angle
        verts' :: [H.Vector]
        verts' = map ((+pos) . rot) verts
        sdlVerts = map convV verts'
    SDL.rendererDrawColor renderer $= V4 255 255 255 255

    -- Would crash if there was a polygon without vertices but that should be impossible
    let edges = zip sdlVerts $ tail sdlVerts ++ [head sdlVerts]
    forM_ edges $ uncurry (SDL.drawLine renderer)
    SDL.drawPoint renderer $ convV pos
