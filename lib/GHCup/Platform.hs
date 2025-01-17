{-# LANGUAGE CPP                   #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE QuasiQuotes           #-}
{-# LANGUAGE TemplateHaskellQuotes #-}


{-|
Module      : GHCup.Plaform
Description : Retrieving platform information
Copyright   : (c) Julian Ospald, 2020
License     : LGPL-3.0
Maintainer  : hasufell@hasufell.de
Stability   : experimental
Portability : portable
-}
module GHCup.Platform where


import           GHCup.Errors
import           GHCup.Types
import           GHCup.Types.Optics
import           GHCup.Types.JSON               ( )
import           GHCup.Utils.Dirs
import           GHCup.Prelude
import           GHCup.Prelude.Logger
import           GHCup.Prelude.Process
import           GHCup.Prelude.String.QQ

#if !MIN_VERSION_base(4,13,0)
import           Control.Monad.Fail             ( MonadFail )
#endif
import           Control.Applicative
import           Control.Exception.Safe
import           Control.Monad
import           Control.Monad.Reader
import           Data.ByteString                ( ByteString )
import           Data.Foldable
import           Data.Maybe
import           Data.Text                      ( Text )
import           Data.Versions
import           Haskus.Utils.Variant.Excepts
import           Prelude                 hiding ( abs
                                                , readFile
                                                , writeFile
                                                )
import           System.Info
import           System.OsRelease
import           Text.PrettyPrint.HughesPJClass ( prettyShow )
import           Text.Regex.Posix

import qualified Data.Text                     as T
import qualified Data.Text.IO                  as T



    --------------------------
    --[ Platform detection ]--
    --------------------------


-- | Get the full platform request, consisting of architecture, distro, ...
platformRequest :: (MonadReader env m, Alternative m, MonadFail m, HasLog env, MonadCatch m, MonadIO m)
                => Excepts
                     '[NoCompatiblePlatform, NoCompatibleArch, DistroNotFound]
                     m
                     PlatformRequest
platformRequest = do
  (PlatformResult rp rv) <- liftE getPlatform
  ar                     <- lE getArchitecture
  pure $ PlatformRequest ar rp rv


getArchitecture :: Either NoCompatibleArch Architecture
getArchitecture = case arch of
  "x86_64"      -> Right A_64
  "i386"        -> Right A_32
  "powerpc"     -> Right A_PowerPC
  "powerpc64"   -> Right A_PowerPC64
  "powerpc64le" -> Right A_PowerPC64
  "sparc"       -> Right A_Sparc
  "sparc64"     -> Right A_Sparc64
  "arm"         -> Right A_ARM
  "aarch64"     -> Right A_ARM64
  what          -> Left (NoCompatibleArch what)


getPlatform :: (Alternative m, MonadReader env m, HasLog env, MonadCatch m, MonadIO m, MonadFail m)
            => Excepts
                 '[NoCompatiblePlatform, DistroNotFound]
                 m
                 PlatformResult
getPlatform = do
  pfr <- case os of
    "linux" -> do
      (distro, ver) <- liftE getLinuxDistro
      pure $ PlatformResult { _platform = Linux distro, _distroVersion = ver }
    "darwin" -> do
      ver <-
        either (const Nothing) Just
          . versioning
          -- TODO: maybe do this somewhere else
          . decUTF8Safe'
        <$> getDarwinVersion
      pure $ PlatformResult { _platform = Darwin, _distroVersion = ver }
    "freebsd" -> do
      ver <-
        either (const Nothing) Just . versioning . decUTF8Safe'
          <$> getFreeBSDVersion
      pure $ PlatformResult { _platform = FreeBSD, _distroVersion = ver }
    "mingw32" -> pure PlatformResult { _platform = Windows, _distroVersion = Nothing }
    what -> throwE $ NoCompatiblePlatform what
  lift $ logDebug $ "Identified Platform as: " <> T.pack (prettyShow pfr)
  pure pfr
 where
  getFreeBSDVersion = lift $ fmap _stdOut $ executeOut "freebsd-version" [] Nothing
  getDarwinVersion = lift $ fmap _stdOut $ executeOut "sw_vers"
                                                        ["-productVersion"]
                                                        Nothing


getLinuxDistro :: (Alternative m, MonadCatch m, MonadIO m, MonadFail m)
               => Excepts '[DistroNotFound] m (LinuxDistro, Maybe Versioning)
getLinuxDistro = do
  -- TODO: don't do alternative on IO, because it hides bugs
  (name, ver) <- handleIO (\_ -> throwE DistroNotFound) $ lift $ asum
    [ liftIO try_os_release
    , try_lsb_release_cmd
    , liftIO try_redhat_release
    , liftIO try_debian_version
    ]
  let parsedVer = ver >>= either (const Nothing) Just . versioning
      distro    = if
        | hasWord name ["debian"]  -> Debian
        | hasWord name ["ubuntu"]  -> Ubuntu
        | hasWord name ["linuxmint", "Linux Mint"] -> Mint
        | hasWord name ["fedora"]  -> Fedora
        | hasWord name ["centos"]  -> CentOS
        | hasWord name ["Red Hat"] -> RedHat
        | hasWord name ["alpine"]  -> Alpine
        | hasWord name ["exherbo"] -> Exherbo
        | hasWord name ["gentoo"]  -> Gentoo
        | hasWord name ["amazonlinux", "Amazon Linux"] -> AmazonLinux
        | otherwise                -> UnknownLinux
  pure (distro, parsedVer)
 where
  hasWord t = any (\x -> match (regex x) (T.unpack t))
   where
    regex x = makeRegexOpts compIgnoreCase execBlank ([s|\<|] ++ x ++ [s|\>|])

  lsb_release_cmd :: FilePath
  lsb_release_cmd = "lsb-release"
  redhat_release :: FilePath
  redhat_release = "/etc/redhat-release"
  debian_version :: FilePath
  debian_version = "/etc/debian_version"

  try_os_release :: IO (Text, Maybe Text)
  try_os_release = do
    Just OsRelease{ name = name, version_id = version_id } <-
      fmap osRelease <$> parseOsRelease
    pure (T.pack name, fmap T.pack version_id)

  try_lsb_release_cmd :: (MonadFail m, MonadIO m)
                      => m (Text, Maybe Text)
  try_lsb_release_cmd = do
    (Just _) <- liftIO $ findExecutable lsb_release_cmd
    name     <- fmap _stdOut $ executeOut lsb_release_cmd ["-si"] Nothing
    ver      <- fmap _stdOut $ executeOut lsb_release_cmd ["-sr"] Nothing
    pure (decUTF8Safe' name, Just $ decUTF8Safe' ver)

  try_redhat_release :: IO (Text, Maybe Text)
  try_redhat_release = do
    t <- T.readFile redhat_release
    let nameRegex n =
          makeRegexOpts compIgnoreCase
                        execBlank
                        ([s|\<|] <> fS n <> [s|\>|] :: ByteString) :: Regex
    let verRegex =
          makeRegexOpts compIgnoreCase
                        execBlank
                        ([s|\<([0-9])+(.([0-9])+)*\>|] :: ByteString) :: Regex
    let nameRe n =
          fromEmpty . match (nameRegex n) $ T.unpack t :: Maybe String
        verRe = fromEmpty . match verRegex $ T.unpack t :: Maybe String
    (Just name) <- pure
      (nameRe "CentOS" <|> nameRe "Fedora" <|> nameRe "Red Hat")
    pure (T.pack name, fmap T.pack verRe)
   where
    fromEmpty :: String -> Maybe String
    fromEmpty "" = Nothing
    fromEmpty s' = Just s'

  try_debian_version :: IO (Text, Maybe Text)
  try_debian_version = do
    ver <- T.readFile debian_version
    pure (T.pack "debian", Just ver)
