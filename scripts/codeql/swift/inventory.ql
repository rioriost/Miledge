/**
 * @name Extracted Swift source inventory
 * @description Lists extracted files to prevent partial scans passing.
 * @kind table
 * @id miledge/swift-source-inventory
 */
import swift

from File file
where file.isSuccessfullyExtracted()
select file.getAbsolutePath()
