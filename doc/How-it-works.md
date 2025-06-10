# OSM Logical History – From OpenStreetMap Technical Diffs to Semantic Object History Reconstruction

## Objective

The objective is to be able to review changes that occurred between two versions of OSM data, in order to evaluate the quality of these changes and, eventually, to correct the data in OSM.

For this, it is necessary to use a data differential between the two versions. The OSM differential format ("diff") is relatively technical and low-level regarding data structure. It is therefore difficult to interpret humanly and to review. Here, we seek to establish a semantic differential, not technical, between the data before and after modification. We are only interested in this subject.

### Problem Posed by OSM Changesets and their Diffs

In OSM, changes are contributed in groups of modifications called "Changesets". These are "Diffs": data differentials with a set of metadata (date, contributor identity, etc.). This differential simply contains the modified objects in their new versions.

Objects in OSM consist of free key-value attributes carrying semantics, as well as geometry (carried directly by points, or indirectly by segmented lines and relations). Objects are also equipped with meta-attributes, such as contributor identity. These objects are versioned as they are modified, with version and deletion meta-attributes ("soft delete").

![OSM object illustration with versions, several stacked versions. https://www.openstreetmap.org/node/6506410029/history](01-osm-history.png)

There is no obligation for semantic consistency in changesets. They can simultaneously involve modification of objects without thematic or geographical connection. A changeset can very well add a house in Brazil and modify the shape of a road in Mongolia (which is nevertheless a discouraged practice). Moreover, unlike what is found for example in relational databases, a changeset is not transactional. A changeset is a work session that can extend over time. It can even contain several versions of the same object.

This structure of OSM object historization and the nature of changesets pose challenges for data analysis (Girres & Touya, 2010).

A changeset is therefore a group of modifications spread geographically, semantically and temporally.

### Semantic Problem Posed by OSM Data Structure

The OSM data model is very simple and very open. All objects carry attributes in the form of "free" key-value pairs, associated with a usage consensus. These attributes define the semantics of objects. There is therefore no equivalence with thematic layers found in the GIS world. Objects can even carry multiple semantics at once, and this number of semantic aspects can even depend on the observer's point of view. For example, an object can be simultaneously a building, a shop and an address (which is not always a recommended practice, but such objects exist in large numbers).

![Example of an OSM object with multiple semantics. https://www.openstreetmap.org/way/156152829](02-osm-multi-semantic.png)

There are also three natures of objects, not defined by attributes: points, segmented lines and relations. Depending on the level of detail of the cartography and the intrinsic complexity of the object, an object can be modeled according to one of these three types. A segmented line has no proper geometry, but references points. Note that in OSM, a polygon is one or more segmented line(s) in a loop, whose surface nature is only defined by the interpretation of attributes.

This modeling flexibility, although advantageous for contributors, complicates data consistency analysis (Fan et al., 2014).

Although each object has an identifier, version number and history as meta-attributes, this history is primarily technical. For example, a school can initially be contributed as a point, which can be deleted before being re-mapped as a polygon. This translates in the history as the deletion of the school object of point type with a first technical identifier, then by the creation of a school object of segmented line type with another technical identifier. There is therefore no link in the history between the two objects, although semantically it is the same school.

To take another more complex example, a road can be cut into several segments to carry different attributes, such as maximum allowed speed. One of the segments keeps the identifier and link with the history, while the other segments are new objects without technical link or history.

![Cutting a segment, creating two new objects.](03-split-way.svg)

Note that objects can carry "business" identifier or reference attributes, for example the reference number of a road carried by several sections or the unique reference of a fire hydrant.

The technical history of objects therefore does not allow making the semantic link between objects before and after modification. An object can even keep its identifier and history, while changing all its attributes and therefore semantics.

### Need to Work at the Semantic Level

As identified by Padilla-Ruiz et al. (2011) in their classification of digital map conflation processes, to limit analysis to real changes in OSM data, it is necessary to process data at the semantic level.

Indeed, deleting a fire station to transform it from a node type object to a polygon amounts to a deletion and creation at the data model level. But at the semantic level, this is interpreted as a simple geometry modification.

Moreover, objects can be modified while remaining present in another form. For example, an object carrying building, shop and address attributes can be split into three distinct objects, whose overall semantics remains equivalent to that of the initial object. According to the quality rules and change monitoring that one wishes to follow, this can be considered as a simple geometry modification, or even not be considered as a change as long as the location remains the same.

![Semantic splitting of an object.](04-split-semantic.svg)

## Context of the Need

The approach detailed here stems from a need of the [Clearance](https://github.com/teritorio/clearance) project. Clearance is a synchronization tool for a copy of an OSM database. As its name indicates, data synchronization is subject to control. This synchronization is not done uniformly, both geographically and temporally. Only modifications locally (geographically) satisfying quality criteria are synchronized. Changes are not processed by chronological version, but by rearrangement of modified objects into "local" groups. The objective is to locally ensure consistency of synchronized data. These local change groups are called "LoCha" (Mohapatra, 2019).

This is where the need to analyze the difference between data already synchronized in the OSM copy and new incoming data from contributions made to OSM comes in. The data to be synchronized is quarantined while validating their quality or correcting them. If these data locally (geographically) meet quality criteria, they are integrated into the synchronized copy. Otherwise, the quarantined data is updated (still in the quarantine copy) until it satisfies quality criteria. This approach of reorganizing changes by LoCha allows problematic areas to be put on hold while continuing to update data elsewhere.

To evaluate quality criteria, it is simpler to do so on a high-level semantic representation, rather than at the level of the OSM diff technical format. It is for this task that we need this semantic differential between two versions of OSM data.

The concepts and implementations detailed here are intended to be more generic than the framework for which we developed them.

Due to the problems described above, OSM technical identifiers are not sustainable over time, nor reliable. Moreover, the reconstruction of semantic object history could contribute to discussions on the subject of permanent identifiers. (https://giswiki.hsr.ch/Permanent_ID_for_OSM https://wiki.openstreetmap.org/wiki/Permanent_ID https://wiki.openstreetmap.org/wiki/Persistent_Place_Identifier)

## Selection and Preparation of OSM Data

The data to be compared is in the OSM data schema. This is a relational and non-geometric structure, nor by thematic layers and not very suitable for processing. It is necessary to calculate complete object geometries and, for example, to determine whether a broken line in a loop is a polygon or not.

On the other hand, objects that do not change are excluded from analysis, as they have no history modification.

## Conflation

Conflation consists of finding objects whose identity seems to correspond between the before and after versions. This also allows identifying objects, in the semantic sense, that were newly created or deleted. This matching is done both on OSM tag semantics and geometry.

This conflation is done iteratively on a set of criteria.

The approach described here is the one currently implemented. Improvements are possible.

### Matching by References

The first criterion for finding objects is to use their business references. In OSM, there can be several reference tags.

If in the before and after versions we find a unique OSM object with the same set of references, we then consider that there is a match.

The reference tags used are the "ref" tag and those starting with "ref:".

In the future, we could handle the case of several OSM objects sharing the same references, as is the case for roads.

### Matching by Distance

For all remaining objects, we calculate a distance matrix between all OSM objects in the before version and those in the after version. We are not talking here about geometric distance, but a distance measuring semantic and spatial similarity.

We consider as matching the before object and after object having the smallest distance, and less than a maximum distance.

We remove these objects from the matrix and iterate until there are no more matching objects.

The iterative approach is similar to Volz, Steffen. (2006). This approach does not come without flaws. In the future, rather than iterating, we could seek to minimize the sum of distances between paired objects.

### Distance Concept

The distance used for matching is not only the Euclidean geometric distance, but based on tag semantics and geometric shapes.

The result is that the matrix is not complete, it is only defined for objects comparable to each other.

#### Geometric Distance

For objects without geometry, such as certain relations, or invalid geometries, the distance is not defined. These objects are therefore not matchable.

Identical geometries have a distance of 0.

For points, we non-linearly interpolate the Euclidean distance in the interval [0; 1]. The idea being to better differentiate small distances than large ones. We obtain the value 1 for a maximum allowed matching distance (200 m). Beyond that, the distance is no longer defined, and therefore matching impossible.

For other types of geometries, if there is no intersection, we use the same distance formulation as for points, but in the interval [0.5; 1]. A penalty of 0.5 being introduced for geometries without intersection.

In the case of an intersection, if one of the two geometries is completely included in the other, the distance is then evaluated at 0 (see below the reason with partial matches). Otherwise, we calculate the ratio between the size of the intersection and the size of the union (value between 0 and 1), that is, the Jaccard distance which is a proven method for performing conflations (Li & Goodchild, 2011). This "size" can be, depending on the case, length or area.

These calculations are performed taking margins (buffers) to handle cases such as quasi-intersections or quasi-inclusions.

This geometric distance has a value between 0 and 1.

#### Semantic Distance Between Tags

OSM tags are key-values in free text. But tags do not all have the same role or importance and must be weighted as proposed by Samal et al. (2004).

- **Concept hierarchy tags**: in OSM, there is a tag nomenclature defining the nature of objects. Keys and values are codified. For example, `highway=motorway` to signify that a way is a highway; or `tourism=information` + `information=board` + `board_type=history` for a tourist information panel about the history of a place.
- **Complementary attribute tags** with free or non-free values, such as `name=*` for the name, or `wheelchair=yes` to signify that the object is wheelchair accessible.

To establish a distance between object tags, we will separate tags into two subgroups: those defining a first-level hierarchical nature and the others.

Objects not sharing first-level hierarchical keys are considered non-comparable, and the semantic distance between them is not defined.

An OSM object can have several first-level tags, for example `amenity=recycling` + `landuse=industrial`.

Among these first-level tags, we can distinguish two types of values:
- Those for which the value changes the nature (`amenity=recycling` or `amenity=driving_school`). Although the key is the same, the objects have nothing similar. We define the distance as worth 1.
- Those for which the value gives a level for an object nature (`highway=motorway`, `highway=unclassified`). Objects are of the same nature and comparable to each other. We define the distance as worth 0.5.

If keys and values are identical, the distance is 0. If keys or values exist only for one of the two objects, the distance is 1.

The distance of tags in this first subgroup is obtained by averaging the unit distances of tags.

Concerning the second subgroup of complementary tags, for each identical key, we calculate the Levenshtein distance of values (number of different characters between the two values), normalized between 0 and 1. Then we average all tags in this second group.

Finally, we sum the distances of the two subgroups, which we divide by two to obtain a semantic distance of tags between 0 and 1.

| Before             | After                       | Tag Distance | Group Distance | Total Distance |
|--------------------|-----------------------------|--------------|----------------|----------------|
| shop=bakery        | shop=bakery                 | 0            |                |                |
|                    | craft=bakery                | 1            |                |                |
|                    |                             |              | 0.5            |                |
| name=Amandine 1900 | name=Amandine               | 0.38         |                |                |
|                    | addr:street=Avenue Tassigny | 1            |                |                |
|                    |                             |              | 0.69           |                |
|                    |                             |              |                | 0.59           |

Example of distance calculation between before and after tags.

This approach to weighting attributes according to their semantic importance is inspired by the work of McKenzie et al. (2014) on matching user-generated points of interest. For the second subgroup, tag natures could be leveraged to calculate distance rather than using a Levenshtein distance completely foreign to content semantics.

### Partial Matching

When a before object is a sub-part of the after object, we will cut the geometry to make only a partial match as proposed by Adams et al. (2015) for roads. This case frequently occurs with roads that can be segmented to carry different attributes, such as speed changes.

The remaining part of the object will be reintroduced into the distance matrix and will be available for new matches.

In the future, we could also imagine making partial matches of tags in the case where there are several first-level tags.

### Simplifications

After these matches, complete or partial objects may remain. In order to improve interpretation, we simplify the result. Remaining partial objects are re-merged with original OSM objects already matched. This is notably the case for objects whose geometry has been enlarged and not finally cut into several objects.

Objects may have changed semantics, and before and after objects are not matchable because of different nature. For example, a bank that became a pizzeria. The semantic matching process will identify the deletion of a bank and the addition of a pizzeria, which is correct. However, these changes occur on the same OSM object, and are not matched with anything. We will as a last resort use the fact that the OSM technical identifier has not changed to match objects despite everything. It is finally indeed a bank that became a pizzeria.

## Implementation

This approach is implemented in the [OpenStreetMap Logical History](https://github.com/teritorio/openstreetmap-logical-history) project.

The project also provides an API that allows calculating semantic history on an area between two dates by retrieving OSM data from an Overpass instance. The result can be visualized here [OpenStreetMap Logical History](https://teritorio.github.io/openstreetmap-logical-history-component/#17.23/43.576258/-1.486139).

## Conclusion

This first implementation of conflation between two OSM versions needs to be improved. But it already allows bringing better information structuration and therefore facilitating change review by proposing a history based on semantics and where objects do not have only one predecessor or successor in history.

In addition to the demonstration project, this implementation is already in place in the Clearance project where it helps detect changes that actually require human review.

This approach brings conflation to OSM data history by recreating a semantic rather than technical history.

The approach presented here opens perspectives for proposing an alternative to unique identifier needs, and proposes a basis for better evaluating OSM data changes over time.

## Bibliography
- Girres, Jean-François & Touya, Guillaume. (2010). Quality Assessment of the French OpenStreetMap Dataset. T. GIS. 14. 435-459. 10.1111/j.1467-9671.2010.01203.x.
- Fan, Hongchao & Zipf, Alexander & Fu, Qing & Neis, Pascal. (2014). Quality assessment for building footprints data on OpenStreetMap. International Journal of Geographical Information Science. 28. 700-719. 10.1080/13658816.2013.867495.
- Padilla-Ruiz, Marta & Lopez-Vazquez, Carlos. (2017). Measuring conflation success. Revista Cartográfica. 41-64. 10.35424/rcarto.v0i94.341.
- Li, Linna & Goodchild, Michael. (2011). An optimisation model for linear feature matching in geographical data conflation. International Journal of Image and Data Fusion. 2. 309-328. 10.1080/19479832.2011.577458.
- McKenzie, Grant & Janowicz, Krzystof & Adams, Benjamin. (2014). A weighted multi-attribute method for matching user-generated Points of Interest. Cartography and Geographic Information Science. 41. 125-137. 10.1080/15230406.2014.880327.
- Mohapatra, Saurav (2019). MaRS: How Facebook keeps maps current and accurate.  https://engineering.fb.com/2019/09/30/ml-applications/mars/
- Volz, Steffen. (2006). An Iterative Approach for Matching Multiple Representations of Street Data. In: Hampe,M. (ed.); Sester,M. (ed.); Harrie, L. (ed.): Proceedings of the JOINT ISPRS Workshop on Multiple Representations and Interoperability of Spatial Data. Vol. XXXVI Part 2/W40, pp. 101-110. 36.
- Müslüm Hacar and Türkay Gökgöz (2019). A New, Score-Based Multi-Stage Matching Approach for Road Network Conflation in Different Road Patterns
- Adams, Benjamin & McKenzie, Grant & Gahegan, Mark. (2015). Frankenplace: Interactive Thematic Mapping for Ad Hoc Exploratory Search. 10.1145/2736277.2741137.
- Samal, Ashok & Seth, Sharad & Cueto, Kevin. (2004). A feature-based approach to conflation of geospatial sources. International Journal of Geographical Information Science. 18. 459-489. 10.1080/13658810410001658076.
