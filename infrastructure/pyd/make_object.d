/*
Copyright 2006, 2007 Kirk McDonald

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/

/++
  This module contains some useful type conversion functions. There are two
  interesting operations involved here:
 
  d_type_: PyObject* -> D type 
 
  __py/py: D type -> PyObject*/PydObject 
 
  The former is handled by d_type, the latter by _py. The py function is
  provided as a convenience to directly convert a D type into an instance of
  PydObject.
 +/
module pyd.make_object;

import python;

import std.array;
import std.algorithm;
import std.complex;
import std.typetuple;
import std.bigint;
import std.traits;
import std.typecons;
import std.metastrings;
import std.conv;
import std.range;

import pyd.pydobject;
import pyd.class_wrap;
import pyd.func_wrap;
import pyd.exception;

class to_conversion_wrapper(dg_t) {
    alias ParameterTypeTuple!(dg_t)[0] T;
    alias ReturnType!(dg_t) Intermediate;
    dg_t dg;
    this(dg_t fn) { dg = fn; }
    PyObject* opCall(T t) {
        static if (is(Intermediate == PyObject*)) {
            return dg(t);
        } else {
            return _py(dg(t));
        }
    }
}
class from_conversion_wrapper(dg_t) {
    alias ParameterTypeTuple!(dg_t)[0] Intermediate;
    alias ReturnType!(dg_t) T;
    dg_t dg;
    this(dg_t fn) { dg = fn; }
    T opCall(PyObject* o) {
        static if (is(Intermediate == PyObject*)) {
            return dg(o);
        } else {
            return dg(d_type!(Intermediate)(o));
        }
    }
}

template to_converter_registry(From) {
    PyObject* delegate(From) dg=null;
}
template from_converter_registry(To) {
    To delegate(PyObject*) dg=null;
}

/**
Extend pyd's conversion mechanism. Will be used by _py only if _py cannot 
convert its argument by regular means.

Params:
dg = A callable which takes a D type and returns a PyObject*, or any 
type convertible by _py.
*/
void d_to_python(dg_t) (dg_t dg) {
    static if (is(dg_t == delegate) && is(ReturnType!(dg_t) == PyObject*)) {
        to_converter_registry!(ParameterTypeTuple!(dg_t)[0]).dg = dg;
    } else {
        auto o = new to_conversion_wrapper!(dg_t)(dg);
        to_converter_registry!(typeof(o).T).dg = &o.opCall;
    }
}

/**
Extend pyd's conversion mechanims. Will be used by d_type only if d_type 
cannot convert its argument by regular means.

Params:
dg = A callable which takes a PyObject*, or any type convertible by d_type,
    and returns a D type.
*/
void python_to_d(dg_t) (dg_t dg) {
    static if (is(dg_t == delegate) && is(ParameterTypeTuple!(dg_t)[0] == PyObject*)) {
        from_converter_registry!(ReturnType!(dg_t)).dg = dg;
    } else {
        auto o = new from_conversion_wrapper!(dg_t)(dg);
        from_converter_registry!(typeof(o).T).dg = &o.opCall;
    }
}

/**
 * Returns a new (owned) reference to a Python object based on the passed
 * argument. If the passed argument is a PyObject*, this "steals" the
 * reference. (In other words, it returns the PyObject* without changing its
 * reference count.) If the passed argument is a PydObject, this returns a new
 * reference to whatever the PydObject holds a reference to.
 *
 * If the passed argument can't be converted to a PyObject, a Python
 * RuntimeError will be raised and this function will return null.
 */
PyObject* _py(T) (T t) {
    static if (!is(T == PyObject*) && is(typeof(t is null)) &&
            !isAssociativeArray!T && !isArray!T) {
        if (t is null) {
            Py_INCREF(Py_None);
            return Py_None;
        }
    }
    static if (isBoolean!T) {
        PyObject* temp = (t) ? Py_True : Py_False;
        Py_INCREF(temp);
        return temp;
    } else static if(isIntegral!T) {
        static if(isUnsigned!T) {
            return PyLong_FromUnsignedLongLong(t);
        }else static if(isSigned!T) {
            return PyLong_FromLongLong(t);
        }
    } else static if (is(T : C_long)) {
        return PyInt_FromLong(t);
    } else static if (is(T : C_longlong)) {
        return PyLong_FromLongLong(t);
    } else static if (isFloatingPoint!T) {
        return PyFloat_FromDouble(t);
    } else static if( isTuple!T) {
        T.Types tuple;
        foreach(i, _t; T.Types) {
            tuple[i] = t[i];
        }
        return PyTuple_FromItems(tuple);
    } else static if (is(Unqual!T _unused : Complex!F, F)) {
        return PyComplex_FromDoubles(t.re, t.im);
    } else static if(is(T == std.bigint.BigInt)) {
        import std.string: format = xformat;
        string num_str = format("%s\0",t);
        return PyLong_FromString(num_str.dup.ptr, null, 10);
    } else static if (is(T : string)) {
        return PyString_FromString((t ~ "\0").ptr);
    } else static if (is(T : wstring)) {
        return PyUnicode_FromWideChar(t, t.length);
    // Converts any array (static or dynamic) to a Python list
    } else static if (isArray!(T)) {
        PyObject* lst = PyList_New(t.length);
        PyObject* temp;
        if (lst is null) return null;
        for(int i=0; i<t.length; ++i) {
            temp = _py(t[i]);
            if (temp is null) {
                Py_DECREF(lst);
                return null;
            }
            // Steals the reference to temp
            PyList_SET_ITEM(lst, i, temp);
        }
        return lst;
    // Converts any associative array to a Python dict
    } else static if (isAssociativeArray!(T)) {
        PyObject* dict = PyDict_New();
        PyObject* ktemp, vtemp;
        int result;
        if (dict is null) return null;
        foreach(k, v; t) {
            ktemp = _py(k);
            vtemp = _py(v);
            if (ktemp is null || vtemp is null) {
                if (ktemp !is null) Py_DECREF(ktemp);
                if (vtemp !is null) Py_DECREF(vtemp);
                Py_DECREF(dict);
                return null;
            }
            result = PyDict_SetItem(dict, ktemp, vtemp);
            Py_DECREF(ktemp);
            Py_DECREF(vtemp);
            if (result == -1) {
                Py_DECREF(dict);
                return null;
            }
        }
        return dict;
    } else static if (is(T == delegate) || is(T == function)) {
        PydWrappedFunc_Ready!(T)();
        return WrapPyObject_FromObject(t);
    } else static if (is(T : PydObject)) {
        return Py_INCREF(t.ptr());
    // The function expects to be passed a borrowed reference and return an
    // owned reference. Thus, if passed a PyObject*, this will increment the
    // reference count.
    } else static if (is(T : PyObject*)) {
        Py_INCREF(t);
        return t;
    // Convert wrapped type to a PyObject*
    } else static if (is(T == class)) {
        // But only if it actually is a wrapped type. :-)
        PyTypeObject** type = t.classinfo in wrapped_classes;
        if (type) {
            return WrapPyObject_FromTypeAndObject(*type, t);
        }
        // If it's not a wrapped type, fall through to the exception.
    // If converting a struct by value, create a copy and wrap that
    } else static if (is(T == struct)) {
        if (is_wrapped!(T*)) {
            T* temp = new T;
            *temp = t;
            return WrapPyObject_FromObject(temp);
        }
    // If converting a struct by reference, wrap the thing directly
    } else static if (is(typeof(*t) == struct)) {
        if (is_wrapped!(T)) {
            if (t is null) {
                Py_INCREF(Py_None);
                return Py_None;
            }
            return WrapPyObject_FromObject(t);
        }
    }
    // No conversion found, check runtime registry
    if (to_converter_registry!(T).dg) {
        return to_converter_registry!(T).dg(t);
    }
    PyErr_SetString(PyExc_RuntimeError, ("D conversion function _py failed with type " ~ typeid(T).toString()).ptr);
    return null;
}

/**
 * Helper function for creating a PyTuple from a series of D items.
 */
PyObject* PyTuple_FromItems(T ...)(T t) {
    PyObject* tuple = PyTuple_New(t.length);
    PyObject* temp;
    if (tuple is null) return null;
    foreach(i, arg; t) {
        temp = _py(arg);
        if (temp is null) {
            Py_DECREF(tuple);
            return null;
        }
        PyTuple_SetItem(tuple, i, temp);
    }
    return tuple;
}

/**
 * Constructs an object based on the type of the argument passed in.
 *
 * For example, calling py(10) would return a PydObject holding the value 10.
 *
 * Calling this with a PydObject will return back a reference to the very same
 * PydObject.
 */
PydObject py(T) (T t) {
    static if(is(T : PydObject)) {
        return t;
    } else {
        return new PydObject(_py(t));
    }
}

/**
 * An exception class used by d_type.
 */
class PydConversionException : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) { 
        super(msg, file, line); 
    }
}

/**
 * This converts a PyObject* to a D type. The template argument is the type to
 * convert to. The function argument is the PyObject* to convert. For instance:
 *
 *$(D_CODE PyObject* i = PyInt_FromLong(20);
 *int n = _d_type!(int)(i);
 *assert(n == 20);)
 *
 * This throws a PydConversionException if the PyObject can't be converted to
 * the given D type.
 */
T d_type(T) (PyObject* o) {
    // This ordering is somewhat important. The checks for Tuple and Complex
    // must be before the check for general structs.

    static if (is(PyObject* : T)) {
        return o;
    } else static if (is(PydObject : T)) {
        return new PydObject(borrowed(o));
    } else static if (is(T == void)) {
        if (o != Py_None) could_not_convert!(T)(o);
        return;
    } else static if (isTuple!T) {
        T.Types tuple;
        if(!PyTuple_Check(o)) could_not_convert!T(o);
        auto len = PyTuple_Size(o);
        if(len != T.Types.length) could_not_convert!T(o);
        foreach(i,_t; T.Types) {
            auto obj =  Py_XINCREF(PyTuple_GetItem(o, i));
            tuple[i] = d_type!_t(obj);
            Py_DECREF(obj);
        }
        return T(tuple);
    } else static if (is(Unqual!T _unused : Complex!F, F)) {
        double real_ = PyComplex_RealAsDouble(o);
        handle_exception();
        double imag = PyComplex_ImagAsDouble(o);
        handle_exception();
        return complex!(F,F)(real_, imag);
    } else static if(is(Unqual!T == std.bigint.BigInt)) {
        if (!PyNumber_Check(o)) could_not_convert!(T)(o);
        string num_str = d_type!string(o);
        if(num_str.endsWith("L")) num_str = num_str[0..$-1];
        return BigInt(num_str);
    } else static if(is(Unqual!T _unused : PydInputRange!E, E)) {
        return cast(T) PydInputRange!E(borrowed(o));
    } else static if (is(T == class)) {
        // We can only convert to a class if it has been wrapped, and of course
        // we can only convert the object if it is the wrapped type.
        if (
            is_wrapped!(T) &&
            PyObject_IsInstance(o, cast(PyObject*)&wrapped_class_type!(T)) &&
            cast(T)((cast(wrapped_class_object!(Object)*)o).d_obj) !is null
        ) {
            return WrapPyObject_AsObject!(T)(o);
        }
        // Otherwise, throw up an exception.
        //could_not_convert!(T)(o);
    } else static if (is(T == struct)) { // struct by value
        if (is_wrapped!(T*) && PyObject_TypeCheck(o, &wrapped_class_type!(T*))) { 
            return *WrapPyObject_AsObject!(T*)(o);
        }// else could_not_convert!(T)(o);
    } else static if (is(typeof(*(T.init)) == struct)) { // pointer to struct   
        if (is_wrapped!(T) && PyObject_TypeCheck(o, &wrapped_class_type!(T))) {
            return WrapPyObject_AsObject!(T)(o);
        }// else could_not_convert!(T)(o);
    } else static if (is(T == delegate)) {
        // Get the original wrapped delegate out if this is a wrapped delegate
        if (is_wrapped!(T) && PyObject_TypeCheck(o, &wrapped_class_type!(T))) {
            return WrapPyObject_AsObject!(T)(o);
        // Otherwise, wrap the PyCallable with a delegate
        } else if (PyCallable_Check(o)) {
            return PydCallable_AsDelegate!(T)(o);
        }// else could_not_convert!(T)(o);
    } else static if (is(T == function)) {
        // We can only make it a function pointer if we originally wrapped a
        // function pointer.
        if (is_wrapped!(T) && PyObject_TypeCheck(o, &wrapped_class_type!(T))) {
            return WrapPyObject_AsObject!(T)(o);
        }// else could_not_convert!(T)(o);
    /+
    } else static if (is(wchar[] : T)) {
        wchar[] temp;
        temp.length = PyUnicode_GetSize(o);
        PyUnicode_AsWideChar(cast(PyUnicodeObject*)o, temp, temp.length);
        return temp;
    +/
    } else static if (is(string : T) || is(char[] : T)) {
        const(char)* result;
        PyObject* repr;
        // If it's a string, convert it
        if (PyString_Check(o) || PyUnicode_Check(o)) {
            result = PyString_AsString(o);
        // If it's something else, convert its repr
        } else {
            repr = PyObject_Repr(o);
            if (repr is null) handle_exception();
            result = PyString_AsString(repr);
            Py_DECREF(repr);
        }
        if (result is null) handle_exception();
        static if (is(string : T)) {
            return to!string(result);
        } else {
            return to!string(result).dup;
        }
    } else static if (isArray!T ||
            (isPointer!T && isStaticArray!(pointerTarget!T))) {
        static if(isPointer!T)
            alias Unqual!(ElementType!(pointerTarget!T)) E;
        else
            alias Unqual!(ElementType!T) E;
        version(Python_2_6_Or_Later) {
            if(PyObject_CheckBuffer(o)) {
                return d_type_buffer!(T)(o);
            }
        }
        if(o.ob_type is array_array_Type) {
            return d_type_array_array!(T,E)(cast(arrayobject*) o);
        }else {
            PyObject* iter = PyObject_GetIter(o);
            if (iter is null) {
                PyErr_Clear();
                could_not_convert!(T)(o);
            }
            scope(exit) Py_DECREF(iter);
            Py_ssize_t len = PyObject_Length(o);
            if (len == -1) {
                PyErr_Clear();
                could_not_convert!(T)(o);
            }

            MatrixInfo!T.unqual _array;
            static if(isDynamicArray!T) {
                _array = new MatrixInfo!T.unqual(len);
            }else static if(isStaticArray!T){
                if(len != T.length) 
                    could_not_convert!T(o, 
                            format("length mismatch: %s vs %s", 
                                len, T.length));
            }
            int i = 0;
            PyObject* item = PyIter_Next(iter);
            while (item) {
                try {
                    _array[i] = d_type!(E)(item);
                } catch(PydConversionException e) {
                    Py_DECREF(item);
                    // We re-throw the original conversion exception, rather than
                    // complaining about being unable to convert to an array. The
                    // partially constructed array is left to the GC.
                    throw e;
                }
                ++i;
                Py_DECREF(item);
                item = PyIter_Next(iter);
            }
            return cast(T) _array;
        }
    } else static if (isFloatingPoint!T) {
        double res = PyFloat_AsDouble(o);
        handle_exception();
        return cast(T) res;
    } else static if(isIntegral!T) {
        if(PyInt_Check(o)) {
            C_long res = PyInt_AsLong(o);
            handle_exception();
            static if(isUnsigned!T) {
                if(res < 0) could_not_convert!T(o, format("%s out of bounds [%s, %s]", res, 0, T.max));
                if(T.max < res) could_not_convert!T(o,format("%s out of bounds [%s, %s]", res, 0, T.max));
                return cast(T) res;
            }else static if(isSigned!T) {
                if(T.min > res) could_not_convert!T(o, format("%s out of bounds [%s, %s]", res, T.min, T.max)); 
                if(T.max < res) could_not_convert!T(o, format("%s out of bounds [%s, %s]", res, T.min, T.max)); 
                return cast(T) res;
            }
        }else if(PyLong_Check(o)) {
            static if(isUnsigned!T) {
                static assert(T.sizeof <= C_ulonglong.sizeof);
                C_ulonglong res = PyLong_AsUnsignedLongLong(o);
                handle_exception();
                // no overflow from python to C_ulonglong,
                // overflow from C_ulonglong to T?
                if(T.max < res) could_not_convert!T(o); 
                return cast(T) res;
            }else static if(isSigned!T) {
                static assert(T.sizeof <= C_longlong.sizeof);
                C_longlong res = PyLong_AsLongLong(o);
                handle_exception();
                // no overflow from python to C_longlong,
                // overflow from C_longlong to T?
                if(T.min > res) could_not_convert!T(o); 
                if(T.max < res) could_not_convert!T(o); 
                return cast(T) res;
            }
        }else could_not_convert!T(o);
    } else static if (isBoolean!T) {
        if (!PyNumber_Check(o)) could_not_convert!(T)(o);
        int res = PyObject_IsTrue(o);
        handle_exception();
        return res == 1;
    }/+ else {
        could_not_convert!(T)(o);
    }+/
    if (from_converter_registry!(T).dg) {
        return from_converter_registry!(T).dg(o);
    }
    could_not_convert!(T)(o);
    assert(0);
}

// (*^&* array doesn't implement the buffer interface, but we still
// want it to copy fast.
T d_type_array_array(T, E)(arrayobject* arr_o) {
    // array.array's data can be got with a single memcopy.
    enforce(arr_o.ob_descr, "array.ob_descr null!");
    char typecode = cast(char) arr_o.ob_descr.typecode;
    switch(typecode) {
        case 'b','h','i','l':
            if(!isSigned!E) 
                could_not_convert!T(cast(PyObject*) arr_o,
                        format("typecode '%c' requires signed integer"
                            " type, not '%s'", typecode, E.stringof));
            break;
        case 'B','H','I','L':
            if(!isUnsigned!E) 
                could_not_convert!T(cast(PyObject*) arr_o,
                        format("typecode '%c' requires unsigned integer"
                            " type, not '%s'",typecode, E.stringof));
            break;
        case 'f','d':
            if(!isFloatingPoint!E) 
                could_not_convert!T(cast(PyObject*) arr_o,
                        format("typecode '%c' requires float, not '%s'",
                            typecode, E.stringof));
            break;
        case 'c','u': 
            break;
        default:
            could_not_convert!T(cast(PyObject*) arr_o,
                    format("unknown typecode '%c'", typecode));
    }

    int itemsize = arr_o.ob_descr.itemsize;
    if(itemsize != E.sizeof) 
        could_not_convert!T(cast(PyObject*) arr_o,
                format("item size mismatch: %s vs %s", 
                    itemsize, E.sizeof));
    Py_ssize_t count = arr_o.ob_size; 
    if(count < 0) 
        could_not_convert!T(cast(PyObject*) arr_o, format("nonsensical array length: %s", 
                    count));
    MatrixInfo!T.unqual _array;
    static if(isDynamicArray!T) {
        _array = new MatrixInfo!T.unqual(count);
    }else {
        if(!MatrixInfo!T.check([count])) 
            could_not_convert!T(cast(PyObject*) arr_o, 
                    format("length mismatch: %s vs %s", count, T.length));
    }
    // copy data, don't take slice
    memcpy(_array.ptr, arr_o.ob_item, count*itemsize);
    //_array[] = cast(E[]) arr_o.ob_item[0 .. count*itemsize];
    return cast(T) _array;
}

T d_type_buffer(T)(PyObject* o) {
    PydObject bob = new PydObject(borrowed(o));
    auto buf = bob.bufferview();
    alias MatrixInfo!T.MatrixElementType ME;
    MatrixInfo!T.unqual _array;
    /+
    if(buf.itemsize != ME.sizeof)
        could_not_convert!T(o, format("item size mismatch: %s vs %s",
                    buf.itemsize, ME.sizeof));
    +/
    if(!match_format_type!ME(buf.format)) {
        could_not_convert!T(o, format("item type mismatch: '%s' vs %s",
                    buf.format, ME.stringof));
    }
    if(buf.has_nd) {
        if(!MatrixInfo!T.check(buf.shape)) 
            could_not_convert!T(o,
                    format("dimension mismatch: %s vs %s",
                        buf.shape, MatrixInfo!T.dimstring));
        if(buf.c_contiguous) {
            // woohoo! single memcpy 
            static if(MatrixInfo!T.isRectArray && isStaticArray!T) {
                memcpy(_array.ptr, buf.buf.ptr, buf.buf.length);
            }else{
                alias MatrixInfo!T.RectArrayType RectArrayType;
                static if(!isStaticArray!(RectArrayType)) {
                    ubyte[] dbuf = new ubyte[](buf.buf.length);
                    memcpy(dbuf.ptr, buf.buf.ptr, buf.buf.length);
                }
                size_t rectsize = ME.sizeof;
                size_t MErectsize = 1;
                foreach(i; MatrixInfo!T.rectArrayAt .. MatrixInfo!T.ndim) {
                    rectsize *= buf.shape[i];
                    MErectsize *= buf.shape[i];
                }
                static if(MatrixInfo!T.isRectArray) {
                    static if(isPointer!T)
                        _array = cast(typeof(_array)) dbuf.ptr;
                    else {
                        static assert(isDynamicArray!T);
                        _array = cast(typeof(_array)) dbuf;
                    }
                }else{
                    // rubbish. much pointer pointing
                    size_t offset = 0;
                    static if(isDynamicArray!T) {
                        _array = new MatrixInfo!T.unqual(buf.shape[0]);
                    }
                    enum string xx = (MatrixInfo!T.matrixIter(
                        "_array", "buf.shape", "_indeces",
                        MatrixInfo!T.rectArrayAt, q{
                    static if(isDynamicArray!(typeof($array_ixn))) {
                        $array_ixn = new typeof($array_ixn)(buf.shape[$i+1]);
                    }
                    static if(is(typeof($array_ixn) == RectArrayType)) {
                        // should be innermost loop
                        assert(offset + rectsize <= buf.buf.length, 
                                "uh oh: overflow!");
                        alias typeof($array_ixn) rectarr;
                        static if(isStaticArray!rectarr) {
                            memcpy($array_ixn.ptr, buf.buf.ptr + offset, rectsize);
                        }else{
                            static assert(isDynamicArray!rectarr);
                        
                            $array_ixn = (cast(typeof($array_ixn.ptr))(dbuf.ptr + offset))
                                [0 .. MErectsize];
                        }
                        offset += rectsize;
                    }
                        },
                        ""));
                    mixin(xx);
                }
            }
        }else if(buf.fortran_contiguous) {
            // really rubbish. no memcpy.
            static if(isDynamicArray!T) {
                _array = new MatrixInfo!T.unqual(buf.shape[0]);
            }else static if(isPointer!T) {
                ubyte[] dubuf = new ubyte[](buf.buf.length);
                _array = cast(typeof(_array)) dubuf.ptr;
                    
            }
            enum string xx = (MatrixInfo!T.matrixIter(
                "_array", "buf.shape", "_indeces",
                MatrixInfo!T.ndim, q{
                static if(isDynamicArray!(typeof($array_ixn))) {
                    $array_ixn = new typeof($array_ixn)(buf.shape[$i+1]);
                }else static if(is(typeof($array_ixn) == ME)) {
                    $array_ixn = buf.item!ME(cast(Py_ssize_t[]) _indeces);
                }
                },
                ""));
            mixin(xx);
        }else {
            // wut?
            could_not_convert!T(o,("todo: know what todo"));
            assert(0);
        }
        return cast(T) _array;
    }else if(buf.has_simple) {
        /*
           static if(isDynamicArray!T) {
           E[] array = new E[](buf.buf.length);
           }else static if(isStaticArray!T) {
           if(buf.buf.length != T.length) 
           could_not_convert!T(o, 
           format("length mismatch: %s vs %s", 
           buf.buf.length, T.length));
           E[T.length] array;
           }
           return cast(T) array;
         */
        assert(0, "py jingo wat we do here?");
    }
    return cast(T) _array;
}

/// Check T against format
/// See_Also:
/// <a href='http://docs.python.org/library/struct.html#struct-format-strings'>
/// Struct Format Strings </a>
bool match_format_type(S)(string format) {
    alias Unqual!S T;
    enforce(format.length > 0);

    bool native_size = false;
    switch(format[0]) {
        case '@':
            // this (*&^& function is not defined
            //PyBuffer_SizeFromFormat()
            native_size = true;
        case '=','<','>','!':
            format = format[1 .. $];
        default:
            break;
    }
    // by typeishness
    switch(format[0]) {
        case 'x', 's', 'p': 
            // don't support these
            enforce(false, "unsupported format: " ~ format); 
        case 'c': 
            break;
        case 'b', 'h','i','l','q': 
            if(!isSigned!S) return false;
            break;
        case 'B', 'H', 'I', 'L','Q': 
            if(!isUnsigned!S) return false;
            break;
        case 'f','d':
            if(!isFloatingPoint!S) return false;
            break;
        case '?': 
            if(!isBoolean!S) return false;
        default:
            enforce(false, "unknown format: " ~ format); 
    }

    // by sizeishness
    if(native_size) {
        // grr
        assert(0, "todo");
    }else{
        switch(format[0]) {
            case 'c','b','B','?':
                return (S.sizeof == 1);
            case 'h','H':
                return (S.sizeof == 2);
            case 'i','I','l','L','f':
                return (S.sizeof == 4);
            case 'q','Q','d':
                return (S.sizeof == 8);
            default:
                enforce(false, "unknown format: " ~ format); 
                assert(0); // seriously, d?
                
        }
    }
}

/**
  Some reflective information about multidimensional arrays

  Handles dynamic arrays, static arrays, and pointers to static arrays.
*/
template MatrixInfo(T) if(isArray!T || 
        (isPointer!T && isStaticArray!(pointerTarget!T))) {
    template _dim_list(T, dimi...) {
        static if(isDynamicArray!T) {
            alias _dim_list!(ElementType!T, dimi,-1) next;
            alias next.list list;
            alias next.elt elt;
            alias next.unqual[] unqual;
        }else static if(isStaticArray!T) {
            alias _dim_list!(ElementType!T, dimi, cast(Py_ssize_t) T.length) next;
            alias next.list list;
            alias next.elt elt;
            alias next.unqual[T.length] unqual;
        }else {
            alias dimi list;
            alias T elt;
            alias Unqual!T unqual;
        }
    }

    string tuple2string(T...)() {
        string s = "[";
        foreach(i, t; T) {
            if(t == -1) s ~= "*";
            else s ~= to!string(t);
            if(i == T.length-1) {
                s ~= "]";
            }else{
                s ~= ",";
            }
        }
        return s;
    }

    bool check(Py_ssize_t[] shape) {
        if (shape.length != dim_list.length) return false;
        foreach(i, d; dim_list) {
            if(dim_list[i] == -1) continue;
            if(d != shape[i]) return false;
        }
        return true;
    }

    string matrixIter(string arr_name, string shape_name, 
            string index_name,
            size_t ndim, 
            string pre_code, string post_code) {
        string s_begin = "{\n";
        string s_end = "}\n";
        static if(isPointer!T) {
            string s_ixn = "(*" ~ arr_name ~ ")";
        }else{
            string s_ixn = arr_name;
        }

        s_begin ~= "size_t[" ~ to!string(ndim) ~ "] " ~ index_name ~ ";\n";
        foreach(i; 0 .. ndim) {
            string s_i = to!string(i);
            s_ixn ~= "["~ index_name ~ "[" ~ s_i ~ "]]";
            string index = index_name~ "[" ~ s_i ~ "]";
            string shape_i = shape_name ~ "[" ~ s_i ~ "]";
            s_begin ~= "for("~index~" = 0;" ~index ~ " < " ~ shape_i ~ 
                "; " ~ index ~ "++) {";
            s_end ~= "}\n";

            string pre_code_i = replace(pre_code, "$array_ixn", s_ixn);
            pre_code_i = replace(pre_code_i, "$i", s_i);
            s_begin ~= pre_code_i;
            string post_code_i = replace(post_code, "$array_ixn", s_ixn);
            post_code_i = replace(post_code_i, "$i", s_i);
            s_end ~= post_code_i;
        }
        return s_begin ~ s_end;
    }

    static if(isPointer!T && isStaticArray!(pointerTarget!T)) {
        alias _dim_list!(pointerTarget!T) _dim;
        /// T, with all nonmutable qualifiers stripped away.
        alias _dim.unqual* unqual;
    }else{
        alias _dim_list!T _dim;
        alias _dim.unqual unqual;
    }
    /// tuple of dimensions of T.
    /// dim_list[0] will be the dimension nearest? from the MatrixElementType
    /// i.e. for double[1][2][3], dim_list == (1, 2, 3).
    /// Lists -1 for dynamic arrays,
    alias _dim.list dim_list;
    /// number of dimensions of this matrix
    enum ndim = dim_list.length;
    /// T is a RectArray if:
    /// * it is any multidimensional static array (or a pointer to)
    /// * it is a 1 dimensional dynamic array
    enum bool isRectArray = staticIndexOf!(-1, dim_list) == -1 || dim_list.length == 1;
    //(1,2,3) -> rectArrayAt == 0 
    //(-1,2,3) -> rectArrayAt == 1 == 3 - 2 == len - max(indexof_rev, 1)
    //(-1,-1,1) -> rectArrayAt == 2 == 3 - 1 == len - max(indexof_rev,1)
    //(-1,-1,-1) -> rectArrayAt == 2 == 3 - 1 == len - max(indexof_rev,1)
    //(2,2,-1) -> rectArrayAt == 2
    enum size_t indexof_rev = staticIndexOf!(-1, Reverse!dim_list);
    /// Highest dimension where it and all subsequent dimensions form a
    /// RectArray.
    enum size_t rectArrayAt = isRectArray ? 0 : dim_list.length - max(indexof_rev, 1);
    template _rect_type(S, size_t i) {
        static if(i == rectArrayAt) {
            alias S _rect_type;
        } else {
            alias _rect_type!(ElementType!S, i+1) _rect_type;
        }
    }
    /// unqualified highest dimension subtype of T forming RectArray
    alias _rect_type!(unqual, 0) RectArrayType;
    /// Pretty string of dimension list for T
    enum string dimstring = tuple2string!(dim_list)();
    /// Matrix element type of T
    /// E.g. immutable(double) for T=immutable(double[4][4])
    alias _dim.elt MatrixElementType;
}

@property PyTypeObject* array_array_Type() {
    static PyTypeObject* m_type;
    if(!m_type) {
        PyObject* array = PyImport_ImportModule("array");
        scope(exit) Py_XDECREF(array);
        m_type = cast(PyTypeObject*) PyObject_GetAttrString(array, "array");
    }
    return m_type;
}

alias d_type!(Object) d_type_Object;

private
void could_not_convert(T) (PyObject* o, string reason = "", 
        string file = __FILE__, size_t line = __LINE__) {
    // Pull out the name of the type of this Python object, and the
    // name of the D type.
    string py_typename, d_typename;
    PyObject* py_type, py_type_str;
    py_type = PyObject_Type(o);
    if (py_type is null) {
        py_typename = "<unknown>";
    } else {
        py_type_str = PyObject_GetAttrString(py_type, cast(const(char)*) "__name__".ptr);
        Py_DECREF(py_type);
        if (py_type_str is null) {
            py_typename = "<unknown>";
        } else {
            py_typename = to!string(PyString_AsString(py_type_str));
            Py_DECREF(py_type_str);
        }
    }
    d_typename = typeid(T).toString();
    string because;
    if(reason != "") because = format(" because: %s", reason);
    throw new PydConversionException(
            format("Couldn't convert Python type '%s' to D type '%s'%s",
                py_typename,
                d_typename,
                because),
            file, line
    );
}
