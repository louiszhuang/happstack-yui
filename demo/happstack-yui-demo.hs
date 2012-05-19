{-# OPTIONS_GHC -F -pgmF trhsx #-}
{-# LANGUAGE FlexibleInstances, QuasiQuotes #-}

module Main where

import Control.Monad
import Control.Monad.Trans
import Data.String
import Data.Unique
import HSX.JMacro
import Happstack.Server
import Happstack.Server.HSP.HTML
import Happstack.YUI
import Language.Javascript.JMacro

instance IntegerSupply (ServerPartT IO) where
    nextInteger = fmap (fromIntegral . (`mod` 1024) . hashUnique) (liftIO newUnique)

main :: IO ()
main =
    simpleHTTP nullConf $
      msum [ implYUISite (fromString "http://localhost:8000") (fromString "/yui")
           , demo
           ]

demo :: ServerPart Response
demo = liftM toResponse $ unXMLGenT
    <html>
      <head>
        <script src="http://localhost:8000/yui/3.5.1/"/>
        <% [jmacro| YUI().use "node" \y -> y.one("h1").set("text", "Set from YUI!") |] %>
      </head>
      <body>
        <h1>Boring unscripted title</h1>
      </body>
    </html>