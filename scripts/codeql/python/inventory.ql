/**
 * @name Extracted Python source inventory
 * @description Lists AST source files to prevent partial scans passing.
 * @kind table
 * @id miledge/python-source-inventory
 */
import python

from Module module
select module.getFile().getAbsolutePath()
