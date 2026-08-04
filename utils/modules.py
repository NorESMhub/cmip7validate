def load_grid_vertex(grid_file, grid_type='p'):
    import numpy as np
    import xarray as xr
    """
    Load vertex data of BLOM ocean grid.

    Args:
        grid_file (str): Path to the grid file.
        grid_type (str): Grid type (e.g., 'p').

    Returns:
        tuple: Latitude, longitude, and extended vertices (clat, clon).
    """
    with xr.open_dataset(grid_file) as grid:
        lat = grid[grid_type + 'lat'].data
        lon = grid[grid_type + 'lon'].data
        clat = grid[grid_type + 'clat'].data
        clon = grid[grid_type + 'clon'].data

    dims = [x + 1 for x in list(lat.shape)]
    clat_new = np.zeros(dims)
    clon_new = np.zeros(dims)
    clat_new[:-1, :-1] = clat[0, :, :]  # lower-left patch
    clat_new[0:-1, -1] = clat[1, :, -1] # last column
    clat_new[-1, 0:-1] = clat[3, -1, :] # last row
    clat_new[-1, -1] = clat[2, -1, -1]  # upper-right corner

    clon_new[:-1, :-1] = clon[0, :, :]
    clon_new[0:-1, -1] = clon[1, :, -1]
    clon_new[-1, 0:-1] = clon[3, -1, :]
    clon_new[-1, -1] = clon[2, -1, -1]

    return lat, lon, clat_new, clon_new

def read_variables(ifile='data/methods.txt'):
    """
    Load variable list with defined methods for plotting

    Args:
        infile (str): input text file

    Returns:
        dictionary: dicts
    """

    import ast
    
    dicts = {}
    
    # Read line by line and split back into pairs
    with open(ifile, "r") as file:
        for line in file:
            if line.startswith('!'):    # Skip comment lines
                continue   
            if line.strip():  # Skip empty lines
                if ":" in line:
                    key_str, value_str = line.strip().split(":", 1)
                    key = ast.literal_eval(key_str.strip())
                    value = ast.literal_eval(value_str.strip())
                    dicts[key] = value
                else:
                    key = ast.literal_eval(line)
                    dicts[key] = None
    
    return dicts

def read_compound_names(infile='data/variables.nml'):
    import re
    strs = []
    pattern = r"'((?:[^']*\.){4}[^']*)'"
    with open(infile) as f:
        lines = f.readlines()
        for line in lines:
            str = re.findall(pattern, line)
            if len(str) > 0:
                strs.append(str[0])
    return strs