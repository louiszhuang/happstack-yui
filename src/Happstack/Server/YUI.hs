{-# LANGUAGE CPP, OverloadedStrings, QuasiQuotes, TemplateHaskell, TypeOperators, ViewPatterns #-}

-- | YUI tools for Happstack.
--
-- Some of the examples assume you're using the @OverloadedStrings@ GHC
-- extension.
module Happstack.Server.YUI
  ( -- * Combo Handler
    implYUISite
  , YUISitemap(..)
  , sitemap
  , route
  , showCSSComboURL
    -- * CSS utilities
  , gridUnit
  , fontSize
    -- * JS utilities
  , createNode
    -- * Bundle utilities
  , isYUIFile
  , readYUIFile
  ) where

import Prelude hiding ((.))

import qualified Data.ByteString as B
import qualified Data.Text       as T
import qualified Web.Routes      as WR

import Control.Category              (Category((.)))
import Control.Monad                 (guard, liftM, void)
import Control.Monad.Trans           (liftIO)
import Data.List                     (intercalate)
import Data.Ratio                    ((%), numerator,denominator)
import Data.Text.Encoding            (encodeUtf8)
import Happstack.Server              (Happstack, Response, neverExpires, setHeaderM, badRequest, ok, toResponse, guessContentTypeM, mimeTypes, lookPairs)
import Happstack.Server.Compression  (compressedResponseFilter)
import Happstack.Server.JMacro       ()
import Happstack.Server.YUI.Bundle   (isYUIFile, readYUIFile)
import HSP                           (XML, renderAsHTML)
import Language.Javascript.JMacro    (JStat(BlockStat), JExpr, jmacro, jmacroE, renderJs, jhFromList, toJExpr)
import Text.Boomerang.TH             (derivePrinterParsers)
import Text.InterpolatedString.Perl6 (qq)
import Text.PrettyPrint              (Style(mode), Mode(OneLineMode), renderStyle, style)
import Text.Printf                   (printf)
import Web.Routes                    (Site, RouteT)
import Web.Routes.Boomerang          (Router, (:-), (<>), (</>), rList, anyText, eos, boomerangSiteRouteT)
import Web.Routes.Happstack          (implSite)
import Web.Routes.TH                 (derivePathInfo)

#if !MIN_VERSION_template_haskell(2,7,0)
import Language.Javascript.JMacro   (JStat(..), JExpr(..), JVal(..), Ident(..))
#endif

-- | The @web-routes@ sitemap for the handler that serves up the YUI
-- bundle.  You can embed this in your own sitemap, something like:
--
-- >data Sitemap = YUI YUISitemap | Home
--
-- The version number of the bundled YUI release is included in the routes
-- for sake of cache-busting: the routes all respond with far-future
-- expiration dates.
--
-- A 'WR.PathInfo' instance is provided in case you're using @web-routes@
-- without @boomerang@.  This isn't recommended for production, however,
-- since the YUI version number is not included in this case.
data YUISitemap
    = SeedURL
    -- ^ [@\/YUI_VERSION\/@]
    --     The YUI seed file plus the configuration for using our own
    --     combo loader.
    | ComboURL
    -- ^ [@\/YUI_VERSION\/combo@]
    --     The combo loader.
    | BundleURL [T.Text]
    -- ^ [@\/YUI_VERSION\/bundle\/\<filename\>@]
    --     Get an individual file without combo loading.
    | ConfigURL
    -- ^ [@\/YUI_VERSION\/config@]
    --     The code for configuring YUI to use our own combo loader.  Not needed
    --     if you use the seed file mentioned above.
    | CSSComboURL
    -- ^ [@\/YUI_VERSION\/css@]
    --     A specialized combo loader for CSS modules, for use in @\<link\/\>@
    --     tags.  Simply list the CSS modules in the query string by name rather
    --     than file path, for example
    --     @\"\/YUI_VERSION\/css?reset&base&fonts&grids\"@.  Order matters;
    --     you'll usually want reset first if you use it.

derivePathInfo ''YUISitemap

derivePrinterParsers ''YUISitemap

-- | A @boomerang@ 'Router' for 'YUISitemap'.  If you embed the
-- @YUISitemap@ in your own, you can also embed this router in your own:
--
-- >import qualified Happstack.Server.YUI as Y
-- >sitemap = (rYUI . ("yui" </> Y.sitemap)) <> rHome
sitemap :: Router () (YUISitemap :- ())
sitemap =
    YUI_VERSION_STR </>
       ( rComboURL . "combo"
      <> rCSSComboURL . "css"
      <> rBundleURL . "bundle" </> rList (anyText . eos)
      <> rConfigURL . "config"
      <> rSeedURL
       )

site :: Happstack m => Site YUISitemap (m Response)
site = boomerangSiteRouteT route sitemap

-- | Mounts a handler for serving YUI.  You can use this if you're not
-- using @web-routes@ in your own application.  See 'YUISitemap' for the
-- routes the mounted handler responds to.
implYUISite :: Happstack m
            => T.Text  -- ^ The URL of your application, e.g. @\"http:\/\/localhost:8000\"@.
            -> T.Text  -- ^ The path under which to mount the YUI handler, e.g. @\"/yui\"@.
            -> m Response
implYUISite domain approot = implSite domain approot site

mkConfig :: Happstack m => RouteT YUISitemap m JStat
mkConfig = do
    comboURL <- WR.showURL ComboURL
    return [jmacro|
       YUI.applyConfig { comboBase: `((T.unpack comboURL) ++ "?")`, root: "" }
    |]

-- | Routes a 'YUISitemap' to its handler.  If you embed @YUISitemap@ in
-- your own sitemap, you can use 'WR.nestURL' in your own routing function
-- to dispatch to this one:
--
-- >import qualified Happstack.Server.YUI as Y
-- >route (YUI url) = nestURL YUI (Y.route url)
route :: Happstack m => YUISitemap -> RouteT YUISitemap m Response
route url = do
    neverExpires
    void compressedResponseFilter
    case url of
      BundleURL (map T.unpack -> paths) ->
        do let name = intercalate "/" paths
           exists <- liftIO $ isYUIFile name
           guard exists
           mime <- guessContentTypeM mimeTypes name
           setHeaderM "Content-Type" mime
           bytes <- liftIO $ readYUIFile name
           ok . toResponse $ bytes
      ComboURL ->
        do qs <- liftM (map fst) lookPairs
           exists <- liftIO $ mapM isYUIFile qs
           if null qs || any not exists
             then badRequest $ toResponse ()
             else do mime <- guessContentTypeM mimeTypes $ head qs
                     setHeaderM "Content-Type" mime
                     bytes <- liftIO $ mapM readYUIFile qs
                     ok $ toResponse $ B.concat bytes
      CSSComboURL ->
        do qs <- liftM (map (css . fst)) lookPairs
           exists <- liftIO $ mapM isYUIFile qs
           if null qs || any not exists
             then badRequest $ toResponse ()
             else do setHeaderM "Content-Type" "text/css"
                     bytes <- liftIO $ mapM readYUIFile qs
                     ok $ toResponse $ B.concat bytes
      ConfigURL ->
        do config <- mkConfig
           ok $ toResponse config
      SeedURL ->
        do config <- mkConfig
           seed <- liftIO $ readYUIFile "yui/yui-min.js"
           setHeaderM "Content-Type" "application/javascript"
           ok $ toResponse $ seed `B.append` (encode . render) config
  where
    render = renderStyle (style { mode = OneLineMode }) . renderJs
    encode = encodeUtf8 . T.pack
    css fn = "css" ++ fn ++ "/css" ++ fn ++ "-min.css"

-- | Helper for building a URL to 'CSSComboURL'.
--
-- >do cssURL <- showCSSComboURL YUI ["reset", "base", "fonts", "grids"]
-- >   unXMLGenT
-- >     <html>
-- >       <head>
-- >         <link href=cssURL rel="stylesheet"/>
-- >       </head>
-- >     </html>
showCSSComboURL :: WR.MonadRoute m
                => (YUISitemap -> WR.URL m)  -- ^ Constructor for 'YUISitemap' inside your own sitemap.
                -> [T.Text]                  -- ^ Names of CSS modules to include, in order.
                -> m T.Text
showCSSComboURL yui ms =
    WR.showURLParams (yui CSSComboURL) [(m,Nothing) | m <- ms]

-- | Gets the class name for the grid unit of the ratio of the two argument
-- integers.  YUI doesn't define redundant classes like \"6\/24\" because
-- that is the same as 1\/4 and presumably for sake of a smaller CSS file.
-- This helper function handles that for you, though:
--
-- >>> gridUnit 6 24
-- "yui3-u-1-4"
-- >>> gridUnit 24 24
-- "yui3-u-1"
--
-- The intention is for this function to be used in templates to create
-- values for class attributes, for example with HSP:
--
-- ><div class=(gridUnit 6 24)>
-- >  <% someContent %>
-- ></div>
gridUnit :: Integer -> Integer -> T.Text
gridUnit n d
  | num == 0           = "yui3-u"
  | (num,den) == (1,1) = "yui3-u-1"
  | otherwise          = [qq|yui3-u-$num-$den|]
  where
    num = numerator $ n % d
    den = denominator $ n % d

-- | Converts a pixel size to a percentage suitable for use
-- with the CSS fonts module:
--
-- >>> fontSize 16
-- "123.1%"
--
-- Useful in generated stylesheets, for example with HSP:
--
-- ><style>
-- >  h1 { font-size: <% fontSize 26 %> }
-- ></style>
fontSize :: Integer -> T.Text
fontSize 10 = "77%"
fontSize 11 = "85%"
fontSize 12 = "93%"
fontSize 13 = "100%"
fontSize 14 = "108%"
fontSize 15 = "116%"
fontSize 16 = "123.1%"
fontSize 17 = "131%"
fontSize 18 = "138.5%"
fontSize 19 = "146.5%"
fontSize 20 = "153.9%"
fontSize 21 = "161.6%"
fontSize 22 = "167%"
fontSize 23 = "174%"
fontSize 24 = "182%"
fontSize 25 = "189%"
fontSize 26 = "197%"
fontSize px =
    T.pack . printf "%.1f%%" $ percentage
  where
    percentage :: Double
    percentage = fromIntegral px * (100 / 13)

-- | Creates a YUI Node object from XML created using HSP, for use with
-- JMacro.  This generates less code than using the @hsx-jmacro@ package to
-- achieve the same effect, since it goes straight to YUI without directly
-- using the DOM itself.  The first argument is the YUI object that gets
-- passed to the function you give to @YUI().use()@.  Such variables are
-- available in antiquotation splices with JMacro:
--
-- @
--do html \<- unXMLGenT \<p>Hello, World!\</p>
--   ok [jmacro| YUI().use \"node\" \\y ->
--                 y.one(\"body\").append(`(y ``createNode`` html`)) |]
-- @
createNode :: JExpr -> XML -> JExpr
createNode y xml = [jmacroE| `(y)`.Node.create(`(renderAsHTML xml)`) |]
