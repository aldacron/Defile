module defile.defile;

private {
    import std.string;
    import std.conv;
    import std.traits;

    import derelict.physfs.physfs;
}

class DefileException : Exception {
    public this( string msg, string file = __FILE__, size_t line = __LINE__ ) {
        this( msg, true, file, line );
    }

    public this( string msg, bool getErrString, string file = __FILE__, size_t line = __LINE__ ) {
        if( getErrString ) {
            msg = format( "%s: %s", msg, Defile.lastError );
        }
        super( msg, file, line, null );
    }
}

enum OpenFor {
    Read,
    Write,
    Append,
}

enum ConfigFlags {
    None = 0x0,
    IncludeCDRoms = 0x1,
    ArchivesFirst = 0x2,
}

enum PathType {
    Write,
    Base,
    User,
}

/++
    A wrapper of the PhysicsFS library, specifically via the DerelictPHYSFS binding.

    In some cases, the methods of Defile directly wrap PhysicsFS functions, doing nothing
    more than converting between C and D types and throwing exceptions when a call
    fails. Other methods are for convenience, wrapping multiple PhysicsFS function
    calls into a single method. For more information on the details of the wrapped
    PhysicsFS functions, please refer either to the PHYSFS documentation or physfs.h.

    Note that the static methods below either wrap functions that work with global
    state or serve as covenience methods that eliminate the need to deal with an
    indivdual file. The nonstatic methods wrap functions that manipulate files
    directly.
+/
struct Defile {
    private static {
        string _baseDir;
        string _userDir;
        string _writeDir;
    }

    public static {
        /++
            Must be called before any other methods.

            Calling other methods without first calling initialize should be
            considered as undefined behavior. The result will almost surely
            be a crash, since this method loads and initializes the PhysicsFS library.

            Throws:
                DerelictException if the physfs library fails to load.
                DefileException if the physfs library fails to initialize.
        +/
        void initialize() {
            import core.runtime;

            DerelictPHYSFS.load();
            if( PHYSFS_init( Runtime.args[ 0 ].toStringz() ) == 0 ) {
                throw new DefileException( "Failed to initialize virtual file system" );
            }

            _baseDir = to!string( PHYSFS_getBaseDir() );
            _userDir = to!string( PHYSFS_getUserDir() );
        }

        /++
            Should be called before the application exits.

            Calling other methods after calling terminate should be considered
            as undefined behavior. The result could vary between crashes due to
            access violations and the throwing of DefileExceptions. It is safe to
            call this even if the initialize method causes an exception to be
            thrown, so, e.g., wrapping it in scope( exit ) is preferable to
            scope( success ).
        +/
        void terminate() {
            if( DerelictPHYSFS.isLoaded ) {
                PHYSFS_deinit();
            }
        }

        /++
            A wrapper for PHYSFS_setSaneConfig.

            Sets an initial search path for the virtual file system. See the
            documentation for PHYSFS_setSaneConfig for details.

            Params:
                organization    = If non-null, the name to be used as the top-level
                                  of the app's write directory tree. Should be the name of
                                  your group or company.
                appName         = The name of the application. Will be a subdirectory
                                  under 'organization' if organization is null, or the
                                  app's top-level write directory.
                archiveExt      = The file extension used by your program to specify
                                  an archive, e.g. "pk3" in Quake3. Note that the archive
                                  format must be one supported by PhysicsFS.
                flags           = If ConfigFlags.IncludeCDRoms is set, the CD-ROM
                                  drive(s) is added to the search path. If
                                  ConfigFlags.ArchivesFirst is set, all archives are
                                  prepended to the search path, otherwise they are
                                  appended.
            Throws:
                DefileException if the call fails.
        +/
        void setSaneConfig( string organization, string appName, string archiveExt, ConfigFlags flags = ConfigFlags.None ) {
            int cds = flags & ConfigFlags.IncludeCDRoms;
            int af = flags & ConfigFlags.ArchivesFirst;
            auto ae = archiveExt is null ? null : archiveExt.toStringz();

            if( PHYSFS_setSaneConfig( organization.toStringz(), appName.toStringz(), ae, cds, af) == 0) {
                throw new DefileException( "Failed to configure virtual file system" );
            }
        }

        /++
            A wrapper for PHYSFS_mkdir.

            Creates a directory on the local file system, including any parent
            directories in the specified path that do not exist. See the documentation
            for PHYSFS_mkdir for details.

            Params:
                dirName = The relative path in the virtual file system of the
                          directory to create.
            Throws:
                DefileException if the call fails.
        +/
        void mkdir( string dirPath ) {
            if( PHYSFS_mkdir( dirPath.toStringz() ) == 0 ) {
                throw new DefileException( "Failed to create directory " ~ dirPath );
            }
        }

        /++
            A wrapper for PHYSFS_delete.

            Deletes a file or directory from the physical file system. See the
            documentation for PHYSFS_delete for details.

            Params:
                path    = The relative path in the virtual file system to the
                          file or directory to delete.
            Throws:
                DefileException if an error occurs.
        +/
        void remove( string path ) {
            if( PHYSFS_delete( path.toStringz() ) == 0 ) {
                throw new DefileException( "Failed to delete file/directory " ~ path );
            }
        }

        /++
            A wrapper for PHYSFS_exists.

            Params:
                filePath = a fileName or relative file path for which to search
                           in the virtual file system search path.
            Returns:
                true if the given path exists anywhere in the PhysicsFS search
                path and false if it does not.
        +/
        bool exists( string filePath ) {
            return PHYSFS_exists( filePath.toStringz() ) != 0;
        }

        /++
            A weapper for PHYSFS_mount.

            Adds a directory or archive to the virtual file system search path.
            See the documentation for PHYSFS_mount for details.

            Params:
                newDir      = directory or archive to add to the search path.
                mountPoint  = location in the tree in which to add newDir. null
                              or "" is equivalent to "/", i.e. the root.
                appendToPath = If true, the path will be appeneded to the search
                               path. If false, the path will be prepended to the
                               search path.
            Throws:
                DefileException if the call fails.
        +/
        void mount( string newDir, string mountPoint, bool appendToPath ) {
            auto mp = mountPoint is null ? null : mountPoint.toStringz();
            if( PHYSFS_mount( newDir.toStringz(), mp, appendToPath ? 1 : 0 ) == 0 ) {
                throw new DefileException( "Failed to mount " ~ newDir );
            }
        }

        /++
            A covenience function that reads the entire content of a file in a
            single method call.

            The method will first open for reading the file specified by filePath
            and determine its length. Then it will call the Defile.read method of
            the file instance, which will allocate or expand the provided buffer
            as necessary.

            Params:
                filePath    = The relative path to the file in the virtual file system.
                buffer      = The buffer in which the content of the file will be
                              stored. The buffer will be allocated if null and
                              expanded if too small.
            Returns:
                The number of bytes read.
            Throws:
                DefileException if an error occurs.
        +/
        size_t readFile( string filePath, ref ubyte[] buffer ) {
            auto file = Defile( filePath, OpenFor.Read );
            auto size = file.length;
            auto ret = file.read( buffer, size, 1 );
            return ret * size;
        }

        /++
            A convenience function that writes an entire buffer to a file in
            a single method call.

            The method will first open for writing the file specified by filePath,
            the will call Defile.write to completely write buffer to the file.

            Params:
                filePath    = The relative path to the file in the virtual file system.
                buffer      = The bytes that will be written to the file.
            Returns:
                The number of bytes written, which should equal buffer.length.
            Throws:
                DefileException if an error occurs.
        +/
        size_t writeFile( string filePath, ubyte[] buffer ) {
            auto file = Defile( filePath, OpenFor.Write );
            auto ret = file.write( buffer, buffer.length, 1 );
            return ret * buffer.length;
        }

        /++
            A convenience function which creates a path string to a file in a
            specific directory.

            Sometimes, a file in the write, base or user directories may need to
            be opened outside of the virtual file system. In those cases, it is
            necessary to query Defile for the path to the directory of interest
            and construct the fill file path. This method condenses that into
            one call.

            Note that this function does not determine if the file exists. It only
            builds the path.

            Params:
                which       = Specifies which directory will comprise the path. One
                              of PathType.Write, PathType.Base or PathType.User.
                fileName    = The name of the file that will be appended to the path.
            Returns:
                A relative path in the virtual file system.
        +/
        string makeFilePath( PathType which, string fileName ) {
            version( Windows ) string fmtString = "%s\\%s";
            else string fmtString = "%s/%s";

            with( PathType ) final switch( which ) {
                case Write:
                    return format( fmtString, _writeDir, fileName );

                case Base:
                    return format( fmtString, _baseDir, fileName );

                case User:
                    return format( fmtString, _userDir, fileName );
            }
        }

        /++
            Searches for a given file in the write and base directories and, if
            it exists, returns a path to the file.

            This method first looks for the file in the write directory. If it
            exists, then a string containing the path "writeDir/fileName" is
            returned. Otherwise, it then looks for the file in the base directory
            and returns its path if found. If the file exists in neither directory,
            the method returns null.

            Params:
                fileName    = The name or relative path of a file to look for.
            Returns:
                A string containing the relative path to the file in the virtual
                file system, or null if the file cannot be found.
        +/
        string findFilePath( string fileName ) {
            auto path = makeFilePath( PathType.Write, fileName );
            if( exists( path )) return path;

            path = makeFilePath( PathType.Base, fileName );
            if( exists( path )) return path;

            return null;
        }

        @property {
            /++
                A wrapper for PHYSFS_getLastError().

                Returns:
                    An string describing the last error to occur in a PHYSFS
                    function call.
            +/
            string lastError() {
                return to!string( PHYSFS_getLastError() );
            }

            /++
                Returns:
                    The application's base directory, i.e. where the executable lives.
            +/
            string baseDir() {
                return _baseDir;
            }

            /++
                Returns:
                    The user directory as specified by the operating system.
            +/
            string userDir() {
                return _userDir;
            }

            /++
                Returns:
                    The current write directory.
            +/
            string writeDir() {
                if( _writeDir !is null ) {
                    return _writeDir;
                } else {
                    _writeDir = to!string( PHYSFS_getWriteDir() );
                    return _writeDir;
                }
            }

            /++
                Sets the current write directory.

                All calls to writeFile or Defile.write will be directed to the
                directory specified here.

                Params:
                    dir = The new write directory.
                Throws:
                    DefileException if the call fails.
            +/
            void writeDir( string dir ) {
                auto ret = PHYSFS_setWriteDir( dir.toStringz() );
                if( ret == 0 ) {
                    throw new DefileException( "Failed to set write directory " ~ dir );
                }
                _writeDir = dir;
            }

            /++
                Returns:
                    An array of strings containing each individual path that is
                    on the virtual file system search path.
            +/
            string[] searchPath()  {
                string[] ret;
                auto list = PHYSFS_getSearchPath();
                for( size_t i = 0; list[ i ]; ++i ) {
                    ret ~= to!string( list[ i ] );
                }
                PHYSFS_freeList( list );
                return ret;
            }
        }
    }

    private {
        string _name;
        PHYSFS_File *_handle;
    }

    public {
        /++
            Opens a file when it is constructed.
        +/
        this( string fileName, OpenFor ofor ) {
            open( fileName, ofor );
        }

        /++
            Closes a file when it goes out of scope.
        +/
        ~this() {
            close();
        }

        /++
            A wrapper for PHYSFS_openRead, PHYSFS_openWrite, and PHYSFS_openAppend.

            A file must be opened before any operations can be performed on it.
            Failure to do so should be considered undefined behavior, but will
            most likely result in exceptions being thrown.

            See the documentation for PHYSFS_openRead, PHYSFS_openWrite and
            PHYSFS_openAppend for more details.

            Params:
                fileName    = The relative path to the file in the virtual file system.
                ofor        = The usage for which the file will be opened, one of
                              OpenFor.Read, OpenFor.Write, or OpenFor.Append.
            Throws:
                DefileException if the file could not be opened.
        +/
        void open( string fileName, OpenFor ofor ) {
            auto cname = fileName.toStringz();
            with( OpenFor ) final switch( ofor ) {
                case Read:
                    _handle = PHYSFS_openRead( cname );
                    break;

                case Write:
                    _handle = PHYSFS_openWrite( cname );
                    break;

                case Append:
                    _handle = PHYSFS_openAppend( cname );
                    break;
            }

            if( !_handle ) {
                throw new DefileException( "Failed to open file " ~ fileName );
            }

            _name = fileName;
        }

        /++
            A wrapper for PHYSFS_close.

            The destructor will close the file automatically, but sometimes it
            is necessary to do so manaualy.
        +/
        void close() {
            if( _handle ) {
                PHYSFS_close( _handle );
                _handle = null;
            }
        }

        /++
            A wrapper for PHYSFS_flush.

            Flushes the files internal buffer. See the documentation for
            PHYSFS_flush for details.

            Throws:
                DefileException if an error occurs.
        +/
        void flush() {
            if( PHYSFS_flush( _handle ) == 0 ) {
                throw new DefileException( "Failed to flush file " ~ _name );
            }
        }

        /++
            A wrapper for PHYSFS_seek.

            Seeks from the beginning of the file to the specified position. See
            the documentation for PHYSFS_seek for details.

            Params:
                position    = The offset from the beginning of the file to move to.
            Throws:
                DefileException if an error occurs.
        +/
        void seek( size_t position ) {
            if( PHYSFS_seek( _handle, position ) == 0 ) {
                throw new DefileException( format( "Failed to seek to position %s in file %s", position, _name ));
            }
        }

        /++
            A wrapper for PHYSFS_tell.

            See the documentation for PHYSFS_tell for details.

            Returns:
                The current file position.
            Throws:
                DefileException if an error occurs.
        +/
        size_t tell() {
            auto ret = PHYSFS_tell( _handle );
            if( ret == -1 ) {
                throw new DefileException( "Failed to determine position in file " ~ _name );
            }
            return cast( size_t )ret;
        }

        /++
            A wrapper for PHYSFS_read.

            Reads data from a file. Note that the file must have been opened
            with the OpenFor.Read flag set. See the documentation for PHYSFS_read
            for details.

            Params:
                buffer      = The byte buffer which will be used to store the data
                              read from the file. If the buffer is null, it will be
                              allocated. If it is too small to hold objSize * objCount
                              bytes, it will be extended.
                objSize     = The number of bytes to read at a time.
                objCount    = The number of times to read objSize bytes.
            Returns:
                The total number of bytes read. Note that this differs from
                PHYSFS_read, which returns the number of objects read.
            Throws:
                DefileException if an error occurs.
        +/
        size_t read( ref ubyte[] buffer, size_t objSize, size_t objCount ) {
            size_t bytesToRead = objSize * objCount;
            if( buffer.length == 0 ) {
                buffer = new ubyte[ bytesToRead ];
            } else if( buffer.length < bytesToRead ) {
                buffer.length += bytesToRead;
            }

            auto ret = PHYSFS_read( _handle, buffer.ptr, cast( uint )objSize, cast( uint )objCount );
            if( ret == -1 ) {
                throw new DefileException( "Failed to read from file " ~ _name );
            }
            return cast( size_t )ret * objSize;
        }

        /++
            A wrapper for PHYSFS_read.

            Reads data from a file. Note that the file must have been opened
            with the OpenFor.Read flag set. See the documentation for PHYSFS_read
            for details.

            Params:
                ptr         = A pointer that will be used to store the objects read
                            = from the file.
                objSize     = The number of bytes to read at a time.
                objCount    = The number of times to read objSize bytes.
            Returns:
                The total number of objects read.
            Throws:
                DefileException if an error occurs.
        +/

        size_t read( void* ptr, size_t objSize, size_t objCount ) {
            auto ret = PHYSFS_read( _handle, ptr, cast( uint )objSize, cast( uint )objCount );
            if( ret == -1 ) {
                throw new DefileException( "Failed to read from file " ~ _name );
            }
            return cast( size_t )ret;
        }

        /++
            A wrapper for PHYSFS_write.

            Writes data to a file. Note that the file must have been opened
            with the OpenFor.Read or OpenFor.Append flag set. See the
            documentation for PHYSFS_write for details.

            Params:
                buffer      = The buffer containing the bytes which will be written
                              to the file.
                objSize     = The number of bytes to write at a time.
                objCount    = The number of times to write objSize bytes.
            Returns:
                The total number of bytes written. Note that this differs from
                PHYSFS_read, which returns the number of objects written.
            Throws:
                DefileException if an error occurs.
        +/
        size_t write( const( ubyte )[] buffer, size_t objSize, size_t objCount ) {
            auto ret = PHYSFS_write( _handle, buffer.ptr, cast( uint )objSize, cast( uint )objCount );
            if( ret == -1 ) {
                throw new DefileException( "Failed to write to file " ~ _name );
            }
            return cast( size_t )ret * objSize;
        }

        /++
            A wrapper for PHYSFS_write.

            Writes data to a file. Note that the file must have been opened
            with the OpenFor.Read or OpenFor.Append flag set. See the
            documentation for PHYSFS_write for details.

            Params:
                ptr         = A pointer to the object(s) that will be written to file.
                objSize     = The number of bytes to write at a time.
                objCount    = The number of times to write objSize bytes.
            Returns:
                The total number of objects written.
            Throws:
                DefileException if an error occurs.
        +/
        size_t write( const( void )* ptr, size_t objSize, size_t objCount ) {
            auto ret = PHYSFS_write( _handle, ptr, objSize, objCount );
            if( ret == -1 ) {
                throw new DefileException( "Failed to write to file " ~ _name );
            }
            return cast( size_t )ret;
        }

        /++
            A templated wrapper for the PHYSFS_readSLE/ULE* functions.

            This method only accepts values that are of any integral type except
            byte and ubyte.

            Returns:
                A value of type T in little endian byte order.
            Throws:
                DefileException if an error occurs.

        +/
        T readLE( T )() if( isIntegral!T && !is( T == byte ) && !is( T == ubyte )) {
            int ret;
            T val;

            static if( is( T == short )) {
                ret = PHYSFS_readSLE16( _handle, &val );
            } else static if( is( T == ushort )) {
                ret = PHYSFS_readULE16( _handle, &val );
            } else static if( is( T == int )) {
                ret = PHYSFS_readSLE32( _handle, &val );
            } else static if( is( T == uint )) {
                ret = PHYSFS_readULE32( _handle, &val );
            } else static if( is( T == long )) {
                ret = PHYSFS_readSLE64( _handle, &val );
            } else static if( is( T == ulong )) {
                ret = PHYSFS_readULE64( _handle, &val );
            } else {
                static assert( 0 );
            }

            if( ret == 0 ) {
                throw new DefileException( format( "Failed to read %s LE value from file %s",
                        T.stringOf, _name ));
            }
            return val;
        }

        /++
            A templated wrapper for the PHYSFS_readSBE/UBE* functions.

            This method only accepts values that are of any integral type except
            byte and ubyte.

            Returns:
                A value of type T in big endian byte order.
            Throws:
                DefileException if an error occurs.

        +/
        T readBE( T )() if( isIntegral!T && !is( T == byte ) && !is( T == ubyte )) {
            int ret;
            T val;

            static if( is( T == short )) {
                ret = PHYSFS_readSBE16( _handle, &val );
            } else static if( is( T == ushort )) {
                ret = PHYSFS_readUBE16( _handle, &val );
            } else static if( is( T == int )) {
                ret = PHYSFS_readSBE32( _handle, &val );
            } else static if( is( T == uint )) {
                ret = PHYSFS_readUBE32( _handle, &val );
            } else static if( is( T == long )) {
                ret = PHYSFS_readSBE64( _handle, &val );
            } else static if( is( T == ulong )) {
                ret = PHYSFS_readUBE64( _handle, &val );
            } else {
                static assert( 0 );
            }

            if( ret == 0 ) {
                throw new DefileException( format( "Failed to read %s BE value from file %s",
                        T.stringOf, _name ));
            }
            return val;
        }

        /++
            A templated wrapper for the PHYSFS_writeSLE/ULE* functions.

            This method only accepts values that are of any integral type except
            byte and ubyte.

            Params:
                val     = A value of type T which will be written to the file in
                          little endian byte order.
            Throws:
                DefileException if an error occurs.

        +/
        void writeLE( T )( T val ) if( isIntegral!T && !is( T == byte ) && !is( T == ubyte )) {
            int ret;

            static if( is( T == short )) {
                ret = PHYSFS_writeSLE16( _handle, val );
            } else static if( is( T == ushort )) {
                ret = PHYSFS_writeULE16( _handle, val );
            } else static if( is( T == int )) {
                ret = PHYSFS_writeSLE32( _handle, val );
            } else static if( is( T == uint )) {
                ret = PHYSFS_writeULE32( _handle, val );
            } else static if( is( T == long )) {
                ret = PHYSFS_writeSLE64( _handle, val );
            } else static if( is( T == ulong )) {
                ret = PHYSFS_writeULE64( _handle, val );
            } else {
                static assert( 0 );
            }

            if( ret == 0 ) {
                throw new DefileException( format( "Failed to write %s LE value to file %s",
                        T.stringOf, _name ));
            }
        }

        /++
            A templated wrapper for the PHYSFS_writeSBE/UBE* functions.

            This method only accepts values that are of any integral type except
            byte and ubyte.

            Params:
                val     = A value of type T which will be written to the file in
                          big endian byte order.
            Throws:
                DefileException if an error occurs.

        +/
        void writeBE( T )( T val ) if( isIntegral!T && !is( T == byte ) && !is( T == ubyte )) {
            int ret;

            static if( is( T == short )) {
                ret = PHYSFS_writeSBE16( _handle, val );
            } else static if( is( T == ushort )) {
                ret = PHYSFS_writeUBE16( _handle, val );
            } else static if( is( T == int )) {
                ret = PHYSFS_writeSBE32( _handle, val );
            } else static if( is( T == uint )) {
                ret = PHYSFS_writeUBE32( _handle, val );
            } else static if( is( T == long )) {
                ret = PHYSFS_writeSBE64( _handle, val );
            } else static if( is( T == ulong )) {
                ret = PHYSFS_writeUBE64( _handle, val );
            } else {
                static assert( 0 );
            }

            if( ret == 0 ) {
                throw new DefileException( format( "Failed to write %s BE value to file %s",
                        T.stringOf, _name ));
            }
        }

        @property {
            /++
                A wrapper for PHYSFS_fileLength.

                Returns:
                    The total size, in bytes, of the file.
            +/
            size_t length() {
                if( !_handle ) return 0;

                auto len = PHYSFS_fileLength( _handle );
                if( len == -1 ) {
                    throw new DefileException( "Invalid length for file " ~ _name );
                }
                return cast( size_t )len;
            }

            /++
                A wrapper for PHYSFS_eof.

                Returns:
                    True if the end of file has been reached, false otherwise.
            +/
            bool eof() {
                if( !_handle ) return true;
                return PHYSFS_eof( _handle ) > 0;
            }

            /++
                A wrapper for PHYSFS_setBuffer.

                Sets the size of the files internal buffer.

                Params:
                    size    = The new buffer size.
                Throws:
                    DefileException if an error occurs.
            +/
            void bufferSize( size_t size ) {
                assert( _handle );
                if( PHYSFS_setBuffer( _handle, size ) == 0 ) {
                    throw new DefileException( "Failed to set buffer size for file " ~ _name );
                }
            }
        }
    }
}