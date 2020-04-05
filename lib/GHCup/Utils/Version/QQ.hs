{-# OPTIONS_GHC -Wno-orphans    #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveLift         #-}
{-# LANGUAGE FlexibleInstances  #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell    #-}


module GHCup.Utils.Version.QQ where

import           Data.Data
import           Data.Text                      ( Text )
import           Data.Versions
import           Language.Haskell.TH
import           Language.Haskell.TH.Quote      ( QuasiQuoter(..) )
import           Language.Haskell.TH.Syntax     ( Lift
                                                , dataToExpQ
                                                )
import qualified Data.Text                     as T
import qualified Language.Haskell.TH.Syntax    as TH



deriving instance Data Versioning
deriving instance Lift Versioning
deriving instance Data Version
deriving instance Lift Version
deriving instance Data SemVer
deriving instance Lift SemVer
deriving instance Data Mess
deriving instance Lift Mess
deriving instance Data PVP
deriving instance Lift PVP
deriving instance Lift VSep
deriving instance Data VSep
deriving instance Lift VUnit
deriving instance Data VUnit

qq :: (Text -> Q Exp) -> QuasiQuoter
qq quoteExp' = QuasiQuoter
  { quoteExp  = (\s -> quoteExp' . T.pack $ s)
  , quotePat  = \_ ->
    fail "illegal QuasiQuote (allowed as expression only, used as a pattern)"
  , quoteType = \_ ->
    fail "illegal QuasiQuote (allowed as expression only, used as a type)"
  , quoteDec  = \_ -> fail
    "illegal QuasiQuote (allowed as expression only, used as a declaration)"
  }

vver :: QuasiQuoter
vver = qq mkV
 where
  mkV :: Text -> Q Exp
  mkV = either (fail . show) liftDataWithText . version

mver :: QuasiQuoter
mver = qq mkV
 where
  mkV :: Text -> Q Exp
  mkV = either (fail . show) liftDataWithText . mess

sver :: QuasiQuoter
sver = qq mkV
 where
  mkV :: Text -> Q Exp
  mkV = either (fail . show) liftDataWithText . semver

vers :: QuasiQuoter
vers = qq mkV
 where
  mkV :: Text -> Q Exp
  mkV = either (fail . show) liftDataWithText . versioning

pver :: QuasiQuoter
pver = qq mkV
 where
  mkV :: Text -> Q Exp
  mkV = either (fail . show) liftDataWithText . pvp

-- https://stackoverflow.com/questions/38143464/cant-find-inerface-file-declaration-for-variable
liftText :: T.Text -> Q Exp
liftText txt = AppE (VarE 'T.pack) <$> TH.lift (T.unpack txt)

liftDataWithText :: Data a => a -> Q Exp
liftDataWithText = dataToExpQ (\a -> liftText <$> cast a)
