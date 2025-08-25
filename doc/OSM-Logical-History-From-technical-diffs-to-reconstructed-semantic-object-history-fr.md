# OSM Logical History – Depuis les diff techniques OpenStreetMap à la reconstruction de l’historique sémantique des objets

Par Frédéric Rodrigo, le 25 août 2025.

## 1 Objectif

L’objectif est de pouvoir passer en revue les changements intervenus entre deux versions des données OSM, dans le but d’évaluer la qualité de ces changements et, éventuellement, de corriger les données dans OSM.

Pour cela, il est nécessaire d’utiliser un différentiel des données entre les deux versions. Le format de différentiel OSM (« diff ») est relativement technique et de bas niveau en ce qui concerne la structure des données. Il est donc difficile à interpréter humainement et à relire. Ici, nous cherchons à établir un différentiel sémantique, et non technique, entre les données avant et après modification. Nous nous intéressons uniquement à ce sujet.

### 1.1 Problème posé par les Changesets OSM et leurs Diffs

Dans OSM, les changements sont contribués en groupes de modifications nommés « Changesets ». Ce sont des « Diffs » : des différentiels de données avec un ensemble de métadonnées (date, identité du contributeur, etc.). Ce différentiel contient simplement les objets modifiés dans leurs nouvelles versions.

Les objets dans OSM sont constitués d’attributs clé-valeur libres portant la sémantique, ainsi que d’une géométrie (porté directement par les points, ou indirectement par les lignes segmentées et les relations). Les objets sont également dotés de méta-attributs, comme l’identité du contributeur. Ces objets sont versionnés au fur et à mesure de leurs modifications, avec les méta-attributs de version et de suppression (« soft delete »).

![Illustration objet OSM avec versions, plusieurs versions empilées. https://www.openstreetmap.org/node/6506410029/history](OSM-Logical-History-Depuis-les-diff-techniques-OpenStreetMap-a-la-reconstruction-de-l-historique-semantique-des-objets/01-osm-history.png)

Il n’y a aucune obligation de cohérence sémantique dans les changesets. Ils peuvent à la fois porter sur la modification d’objets sans lien thématique, ni géographique. Un changeset peut très bien ajouter une maison au Brésil et modifier la forme d’une route en Mongolie (ce qui n’est toutefois une pratique déconseillée). De plus, contrairement à ce que l’on trouve par exemple dans les bases de données relationnelles, un changeset n’est pas transactionnel. Un changeset est une session de travail qui peut s’étaler dans le temps. Il peut même contenir plusieurs versions d’un même objet.

Cette structure d’historisation des objets OSM et la nature des changesets posent des défis pour l'analyse des données [^1].

Un changeset est donc un groupe de modifications étalées géographiquement, sémantiquement et temporellement.

### 1.2 Problème de sémantique posé par la structure des données d’OSM

Le modèle de données d’OSM est très simple et très ouvert. Tous les objets portent des attributs sous forme de clé-valeur « libres », associés à un consensus d’usages. Ce sont ces attributs qui définissent la sémantique des objets. Il n’y a donc pas d’équivalence avec des calques thématiques que l’on retrouve dans le monde des SIG. Les objets peuvent même porter plusieurs sémantiques à la fois, et ce nombre d’aspects sémantiques peut même dépendre du point de vue de l’observateur. Par exemple, un objet peut être à la fois un bâtiment, un commerce et une adresse (ce qui n’est pas toujours une pratique recommandée, mais de tels objets existent en grand nombre).

![Exemple d’un objet OSM avec plusieurs émantiques. https://www.openstreetmap.org/way/156152829](OSM-Logical-History-Depuis-les-diff-techniques-OpenStreetMap-a-la-reconstruction-de-l-historique-semantique-des-objets/02-osm-multi-semantic.png)

Il y a également trois natures d’objets, non définies par les attributs : les points, les lignes segmentées et les relations. Suivant le niveau de détail de la cartographie et la complexité intrinsèque de l’objet, un objet peut être modélisé selon un de ces trois types. Une ligne segmentée n’a pas de géométrie propre, mais référence des points. À noter que dans OSM, un polygone est une ou plusieurs ligne(s) segmentée(s) en boucle, dont la nature surfacique n’est définie que par l’interprétation des attributs.

Cette flexibilité de modélisation, bien qu'avantageuse pour les contributeurs, complique l'analyse de cohérence des données [^2].

Bien que chaque objet possède en méta-attribut un identifiant, un numéro de version et un historique, cet historique est avant tout technique. Par exemple, une école peut initialement être contribué sous forme d’un point, qui peut être supprimé avant d’être à nouveau re-cartographiée sous forme de polygone. Cela se traduit dans l’historique par la suppression de l’objet école de type point avec un premier identifiant technique, puis par la création d’un objet école de type ligne segmentée avec un autre identifiant technique. Il n’y a donc pas de lien dans l’historique entre les deux objets, bien que sémantiquement il s’agisse de la même école.

Pour prendre un autre exemple plus complexe, une route peut être découpée en plusieurs segments pour porter des attributs différents, comme la vitesse maximale autorisée. Un des segments garde l’identifiant et le lien avec l’historique, tandis que les autres segments sont de nouveaux objets sans lien ni technique, ni d’historique.

![Découpe d’un segment, créant deux nouveaux objets.](OSM-Logical-History-Depuis-les-diff-techniques-OpenStreetMap-a-la-reconstruction-de-l-historique-semantique-des-objets/03-split-way.svg)

À noter que les objets peuvent porter des attributs d’identifiant ou de référence « métiers », par exemple le numéro de référence d’une route porté par plusieurs tronçons ou la référence unique d’une borne incendie.

L’historique technique des objets ne permet donc pas de faire le lien sémantique entre les objets avant et après modification. Un objet peut même conserver son identifiant et son historique, tout en changeant tous ces attributs et donc de sémantique.

### 1.3 Besoin de travailler au niveau sémantique

Comme identifié par Padilla-Ruiz et al. (2017)[^3] dans leur classification des processus de conflation de cartes numériques. Pour limiter l’analyse aux changements réels des données OSM, il est nécessaire de traiter les données au niveau sémantique.

En effet, la suppression d’une caserne de pompiers pour la transformer d’un type d’objet nœud à un polygone revient à une suppression et une création au niveau du modèle de données. Mais au niveau sémantique, cela s’interprète comme une simple modification de géométrie.

De plus, des objets peuvent être modifiés tout en restant présents sous une autre forme. Par exemple, un objet portant des attributs de bâtiment, de commerce et d’adresse peut être scindé en trois objets distincts, dont la sémantique globale reste équivalente à celle de l’objet initial. Selon les règles de qualité et surveillance des changements que l’on souhaite suivre, cela peut être considéré comme une simple modification de géométrie, ou même ne pas être considéré comme un changement tant que la localisation reste la même.

![Découpe sémantique d’un objet.](OSM-Logical-History-Depuis-les-diff-techniques-OpenStreetMap-a-la-reconstruction-de-l-historique-semantique-des-objets/04-split-semantic.svg)

## 2 Contexte du besoin

L’approche détaillée ici découle d’un besoin du projet [Clearance](https://github.com/teritorio/clearance). Clearance est un outil de synchronisation d’une copie d’une base de données OSM. Comme son nom l’indique, la synchronisation des données est soumise à contrôle. Cette synchronisation ne se fait pas de manière uniforme, à la fois géographiquement et temporellement. Seules les modifications satisfaisant localement (géographiquement) les critères de qualité sont synchronisées. Les changements ne sont pas traités par version chronologique, mais par un réarrangement des objets modifiés en groupes « locaux ». L’objectif est d’assurer localement la cohérence des données synchronisées. Ces groupes de changements locaux sont nommés « LoCha » (Mohapatra, 2019)[^4].

C’est ici qu’intervient le besoin d'analyser la différence entre les données déjà synchronisées dans la copie d’OSM et les nouvelles données entrantes depuis les contributions faites à OSM. Les données à synchroniser sont mises en quarantaine le temps de valider leur qualité ou de les corriger. Si ces données répondent localement (géographiquement) aux critères de qualité, elles sont intégrées à la copie synchronisée. Sinon, les données en quarantaine sont mises à jour (toujours dans la copie en quarantaine) jusqu’à ce qu’elles satisfassent les critères de qualité. Cette approche de réorganisation des changements par LoCha permet de mettre en attente les zones problématiques tout en continuant de mettre à jour les données ailleurs.

Pour évaluer les critères de qualité, il est plus simple de le faire sur une représentation sémantique de haut niveau, plutôt qu’au niveau du format technique des diff OSM. C’est pour cette tâche que nous avons besoin de ce différentiel sémantique entre deux versions des données OSM.

Les concepts et implémentations détaillés ici se veulent plus génériques que le cadre pour lequel nous les avons développés.

En raison des problématiques décrites ci-dessus, les identifiants techniques OSM ne sont pas pérennes dans le temps, ni fiables. De plus, la reconstruction de l’historique sémantique des objets pourrait contribuer aux discussions sur le sujet des d’identifiants permanents. (https://giswiki.hsr.ch/Permanent_ID_for_OSM https://wiki.openstreetmap.org/wiki/Permanent_ID https://wiki.openstreetmap.org/wiki/Persistent_Place_Identifier )

## 3 Sélection et préparation des données OSM

Les données à comparer sont dans le schéma de données d’OSM. C’est une structure relationnelle et non géométrique, ni par calques thématiques et peu propice aux traitements. Il est nécessaire de calculer les géométries complètes des objets et, par exemple, de déterminer si une ligne brisée en boucle est un polygone ou non.

D’autre part, les objets qui ne changent pas sont exclus de l’analyse, car ils n’ont pas de modification d’historique.

## 4 Conflation

La conflation consiste à retrouver les objets dont l’identité semble correspondre entre les versions avant et après. Cela permet également d’identifier les objets, au sens sémantique, qui ont été nouvellement créés ou supprimés. Ce rapprochement est fait à la fois sur la sémantique des tags OSM et la géométrie.

Cette conflation se fait itérativement sur un ensemble de critères.

L’approche décrite ici est celle actuellement implémentée. Des améliorations sont possibles.

### 4.1 Rapprochement par références

Le premier critère pour retrouver les objets est d’utiliser leurs références métiers. Dans OSM, il peut y avoir plusieurs tags de références.

Si dans les versions avant et après on retrouve un unique objet OSM avec le même ensemble de références, on considère alors qu’il y a correspondance.

Les tags de références utilisés sont le tag « ref » et ceux commençant par « ref: ».

À l’avenir, on pourrait traiter le cas de plusieurs objets OSM partageant les mêmes références, comme c’est le cas pour les routes.

### 4.2 Rapprochement par distance

Pour tous les objets restants, on calcule une matrice de distances entre tous les objets OSM dans la version avant et ceux de la version après. On ne parle pas ici de distance géométrie, mais d’une distance mesurant la similitude sémantique et spatiale.

On considère comme étant en correspondance l’objet avant et l’objet après ayant la distance la plus petite, et inférieure a une distance maximale.

On supprime ces objets de la matrice et on itère jusqu’à ce qu’il ne reste plus d’objets en correspondance.

L’approche par itération est similaire à Volz, Steffen. (2006)[^5]. Cette approche ne vient pas sans défault. À l’avenir, plutôt que d’itérer, on pourrait chercher à minimiser la somme des distances entre les objets appairés.

### 4.3 Notion de distance

La distance utilisée pour le rapprochement n’est pas uniquement la distance géométrique euclidienne, mais basée sur la sémantique des tags et les formes géométriques.

Il en résulte que la matrice n’est pas complète, elle n’est définie que pour les objets comparables entre eux.

#### 4.3.1 Distance géométrique

Pour des objets sans géométrie, comme certaines relations, ou des géométries invalides, la distance n’est pas définie. Ces objets ne sont donc pas appariables.

Des géométries identiques ont une distance de 0.

Pour les points, on interpole de façon non linéaire la distance euclidienne dans l’intervalle [0 ; 1]. L’idée étant de plus différencier les petites distances que les grandes. On obtient la valeur 1 pour une distance maximale de rapprochement autorisée (200 m). Au-delà, la distance n’est plus définie, et donc le rapprochement impossible.

Pour les autres types de géométries, s’il n’y a pas d’intersection, on utilise la même formulation de distance que pour les points, mais dans l’intervalle [0,5 ; 1]. Une pénalité de 0,5 étant introduite pour les géométries sans intersection.

Dans le cas d’une intersection, si une des deux géométries est complètement incluse dans l’autre, la distance est alors évaluée à 0 (voir plus bas la raison avec les mises en correspondances partielles). Sinon, on calcule le rapport entre la taille de l’intersection et la taille de l’union (valeur entre 0 et 1), c’est-à-dire la distance de Jaccard qui est une méthode éprouve pour réaliser des conflations (Li & Goodchild, 2011). Cette « taille » peut être, selon le cas, la longueur ou la surface.

Ces calculs sont effectués en prenant des marges (buffers) pour traiter des cas comme les quasi-intersections ou les quasi-inclusions.

Cette distance géométrique a une valeur comprise entre 0 et 1.

#### 4.3.2 Distance sémantique entre les tags

Les tags OSM sont des clés-valeurs en texte libre. Mais les tags n’ont pas tous le même rôle ni la même importance et doivent être pondéré comme le propose Samal et al. (2004)[^6].

- **Tags de hiérarchie de concepts** : dans OSM, il existe une nomenclature de tags définissant la nature des objets. Les clés et les valeurs sont codifiées. Par exemple, « highway=motorway » pour signifier qu’une voie est une autoroute ; ou encore « tourism=information » + « information=board » + « board_type=history » pour un panneau d’information touristique sur l’histoire d’un lieu.
- **Tags d’attributs complémentaires** à valeurs libres ou non, comme « name=* » pour le nom, ou « wheelchair=yes » pour signifier que l’objet est accessible en fauteuil roulant.

Pour établir une distance entre les tags des objets, on va séparer les tags en deux sous-groupes : ceux définissant une nature de premier niveau hiérarchique et les autres.

Les objets ne partageant pas de clés de premier niveau hiérarchique sont considérés comme non comparables, et la distance sémantique entre eux n’est pas définie.

Un objet dans OSM peut avoir plusieurs tags de premier niveau, par exemple « amenity=recycling » + « landuse=industrial ».

Parmi ces tags de premier niveau, on peut distinguer deux types de valeurs :
- Celles pour lesquelles la valeur change la nature (« amenity=recycling » ou « amenity=driving_school »). Bien que la clé soit la même, les objets n’ont rien de similaire. On définit la distance comme valant 1.
- Celles pour lesquelles la valeur donne un niveau pour une nature d’objet (« highway=motorway », « highway=unclassified »). Les objets sont de même nature et comparables entre eux. On définit la distance comme valant 0,5.

Si les clés et valeurs sont identiques, la distance est de 0. Si les clés ou valeurs n’existent que pour un des deux objets, la distance est de 1.

La distance des tags de ce premier sous-groupe est obtenue par la moyenne des distances unitaires des tags.

Concernant le second sous-groupe de tags complémentaires, pour chaque clé identique, on calcule la distance de Levenshtein des valeurs (nombre de caractères différents entre les deux valeurs), normalisée entre 0 et 1. Puis on fait la moyenne de l’ensemble des tags de ce second groupe.

Enfin, on fait la somme des distances des deux sous-groupes, que l’on divise par deux pour obtenir une distance sémantique des tags comprise entre 0 et 1.

| Avant              | Après                       | Distance tag | Distance groupe | Distance totale |
|--------------------|-----------------------------|--------------|-----------------|-----------------|
| shop=bakery        | shop=bakery                 | 0            |                 |                 |
|                    | craft=bakery                | 1            |                 |                 |
|                    |                             |              | 0,5             |                 |
| name=Amandine 1900 | name=Amandine               | 0,38         |                 |                 |
|                    | addr:street=Avenue Tassigny | 1            |                 |                 |
|                    |                             |              | 0,69            |                 |
|                    |                             |              |                 | 0,59            |

[Exemple de calcul de la distance entre les tags avant et après.]

Cette approche de pondération des attributs selon leur importance sémantique et s'inspire des travaux de McKenzie et al (2014) [^7] sur l'appariement de points d'intérêt générés par les utilisateurs. Pour le second sous groupe, les natures des tags pourraient être mis à profit pour calculer la distance plutôt que d’utiliser une distance de Levenshtein complètement étrangère à la sémantique du contenu.

###  4.4 Mise en correspondance partielle

Lorsqu’un objet avant est une sous-partie de l’objet après, on va découper la géométrie pour ne faire qu’une mise en correspondance partielle comme proposer par Adams et al (2015)[^8] pour la voirie. Ce cas arrive fréquemment avec des routes qui peuvent être segmentées pour porter des attributs différents, comme des changements de vitesse.

La partie restante de l’objet sera réintroduite dans la matrice de distances et sera disponible pour de nouvelles mises en correspondance.

À l’avenir, on pourrait aussi imaginer faire des mises en correspondances partielles des tags dans le cas où il y a plusieurs tags de premier niveau.

### 4.5 Simplifications

Après ces mises en correspondance, il peut rester des objets complets ou partiels. Dans le but d’améliorer l’interprétation, on simplifie le résultat. Les objets partiels restants sont re-fusionnés avec les objets OSM origines déjà mis en correspondance. C’est notamment le cas des objets dont la géométrie a été agrandie et non finalement découpée en plusieurs objets.

Des objets peuvent avoir changé de sémantique, et les objets avant et après ne sont pas rapprochables car de nature différente. Par exemple, une banque qui est devenue une pizzeria. Le processus de mise en correspondance sémantique va identifier la suppression d’une banque et l’ajout d’une pizzeria, ce qui est correct. Cependant, ces changements interviennent sur le même objet OSM, et ne sont mis en correspondance de rien. On va en dernier recours utiliser le fait que l’identifiant technique OSM n’a pas changé pour rapprocher les objets malgré tout. C’est finalement bien une banque qui est devenue une pizzeria.

## 5 Implémentation

Cette approche est implémentée dans le projet [OpenStreetMap Logical History](https://github.com/teritorio/openstreetmap-logical-history).

Le projet met également à disposition une API qui permet de calculer l’historique sémantique sur une zone entre deux dates en récupérant les données OSM depuis une instance Overpass. Le résultat peut être visualisé ici [OpenStreetMap Logical History](https://teritorio.github.io/openstreetmap-logical-history-component/#17.23/43.576258/-1.486139).

## 6 Conclusion

Cette première implémentation de conflation entre deux versions d’OSM demande à être amélioré, Mais elle permet déjà d’apporter une meilleure structuration de l’information et donc de faciliter la relecture des changements en proposant un historique basé sur la sémantique et où les objets n’ont pas qu’un seul prédécesseur ou successeur dans l’historique.

En plus du projet de démonstration, cette implémentation est déjà en place dans le projet Clearance ou elle aide à détecter les changements nécessitant effectivement une relecture humaine.

Cette approche apporte une conflation dans l’historique des données d’OSM en récréent un historique sémantique plutôt que technique.

L’approche exposée ici ouvre des perspectives pour proposer une alternative aux besoins d’identifiant unique, et propose une base pour mieux évaluer les changements des données d’OSM dans le temps.



[^1]: Girres, Jean-François & Touya, Guillaume. (2010). Quality Assessment of the French OpenStreetMap Dataset. T. GIS. 14. 435-459. 10.1111/j.1467-9671.2010.01203.x.

[^2]: Fan, Hongchao & Zipf, Alexander & Fu, Qing & Neis, Pascal. (2014). Quality assessment for building footprints data on OpenStreetMap. International Journal of Geographical Information Science. 28. 700-719. 10.1080/13658816.2013.867495.

[^3]: Padilla-Ruiz, Marta & Lopez-Vazquez, Carlos. (2017). Measuring conflation success. Revista Cartográfica. 41-64. 10.35424/rcarto.v0i94.341.

[^4]: Mohapatra, Saurav (2019). MaRS: How Facebook keeps maps current and accurate.  https://engineering.fb.com/2019/09/30/ml-applications/mars/

[^5]: Volz, Steffen. (2006). An Iterative Approach for Matching Multiple Representations of Street Data. In: Hampe,M. (ed.); Sester,M. (ed.); Harrie, L. (ed.): Proceedings of the JOINT ISPRS Workshop on Multiple Representations and Interoperability of Spatial Data. Vol. XXXVI Part 2/W40, pp. 101-110. 36.

[^6]: Samal, Ashok & Seth, Sharad & Cueto, Kevin. (2004). A feature-based approach to conflation of geospatial sources. International Journal of Geographical Information Science. 18. 459-489. 10.1080/13658810410001658076.

[^7]: McKenzie, Grant & Janowicz, Krzystof & Adams, Benjamin. (2014). A weighted multi-attribute method for matching user-generated Points of Interest. Cartography and Geographic Information Science. 41. 125-137. 10.1080/15230406.2014.880327.

[^8]: Adams, Benjamin & McKenzie, Grant & Gahegan, Mark. (2015). Frankenplace: Interactive Thematic Mapping for Ad Hoc Exploratory Search. 10.1145/2736277.2741137.

[^9]: Li, Linna & Goodchild, Michael. (2011). An optimisation model for linear feature matching in geographical data conflation. International Journal of Image and Data Fusion. 2. 309-328. 10.1080/19479832.2011.577458.

[^10]: Müslüm Hacar and Türkay Gökgöz (2019). A New, Score-Based Multi-Stage Matching Approach for Road Network Conflation in Different Road Patterns
